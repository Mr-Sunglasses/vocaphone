package com.vocahq.vocaphone.telemetry

import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.settings.SettingsRepository
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray

/**
 * Everything the rest of the app is allowed to report.
 *
 * ## Why every function takes enums
 *
 * There is no `track(name: String, props: Map<String, Any>)` here, and there
 * must never be one. Each event gets its own function whose parameters are
 * enums from `TelemetryEvent.kt`, which means a call site physically cannot
 * pass a transcript, a gateway URL, a file path, or a token — not because
 * reviewers will catch it, but because no parameter accepts a string.
 * `TelemetryVocabularyTest` asserts this by reflection and fails the build if a
 * future function breaks the rule.
 *
 * ## What happens when reporting is off
 *
 * Nothing is queued. Not "queued and discarded at flush" — the check happens
 * before a [TelemetryRecord] is ever constructed, so the interesting failure
 * mode (a queue quietly filling while the switch is off, then flooding the
 * moment someone turns it on) cannot occur.
 *
 * ## What happens in a build that must not transmit
 *
 * Nothing here checks. Whether this build can reach the network is decided once,
 * at construction, by which [TelemetrySink] is bound: the F-Droid flavour and
 * debug builds get [NoOpTelemetrySink]. Events still queue there, which is
 * deliberate — it is what makes the "See what's sent" screen work while
 * developing the feature, without a byte leaving the phone.
 */
class Telemetry internal constructor(
    private val preferences: TelemetryPreferences,
    private val scope: CoroutineScope,
    private val sink: TelemetrySink,
    private val queue: TelemetryQueue = TelemetryQueue(),
    private val session: TelemetrySession = TelemetrySession(),
    private val systemProps: () -> TelemetrySystemProps = TelemetrySystemProps::current,
    private val clock: () -> Instant = Instant::now,
    /**
     * How long to wait after an event before sending. `null` disables the
     * automatic flush entirely, which is what most tests want so that a batch
     * count means what the test says it means.
     */
    private val autoFlushDelayMillis: Long? = TelemetryConfig.FLUSH_DEBOUNCE_MILLIS,
) {

    private var flushJob: Job? = null

    /**
     * Content-free counters for the "See what's sent" screen.
     *
     * This exists because the delivery path is deliberately silent — it swallows
     * every failure so a network problem can never surface to someone who did
     * not ask for this feature to work. That is right in production and useless
     * when the feature appears broken on a real phone: an empty queue means
     * either "delivered" or "never recorded", and nothing on the device could
     * tell those apart. Debugging it meant guessing.
     *
     * Counts and an outcome name, nothing else. Same class of data as the
     * in-memory operational metrics the gateway already keeps: no event names,
     * no properties, no content of any kind.
     */
    private val stats = TelemetryStats()

    constructor(settings: SettingsRepository, scope: CoroutineScope) : this(
        preferences = SettingsTelemetryPreferences(settings),
        scope = scope,
        sink = if (TelemetryConfig.canTransmit) AptabaseSink() else NoOpTelemetrySink,
    )

    // MARK: - Events

    /** Once per install, ever. The denominator for every ratio in the funnel. */
    fun appFirstOpen() = recordOnce(TelemetryEvent.APP_FIRST_OPEN)

    /** Once per step, ever, so a user who redoes setup does not double-count. */
    fun setupStepCompleted(step: TelemetrySetupStep) =
        recordOnce(TelemetryEvent.SETUP_STEP_COMPLETED, "step" to step.wire, key = step.wire)

    fun setupFinished() = recordOnce(TelemetryEvent.SETUP_FINISHED)

    /** Repeats on purpose: switching back to the gateway after trying on-device is a signal. */
    fun sourceSelected(source: TelemetrySource) =
        record(TelemetryEvent.SOURCE_SELECTED, "source" to source.wire)

    /**
     * Takes the descriptor rather than its id so the value can only originate in
     * the shipped catalog, and [TelemetryModelId.pinned] re-checks it against
     * that catalog anyway. Every property whose value begins life as a string
     * goes through that one function.
     */
    fun modelDownloadFinished(model: LocalModelDescriptor, outcome: TelemetryDownloadOutcome) =
        record(
            TelemetryEvent.MODEL_DOWNLOAD_FINISHED,
            "model_id" to TelemetryModelId.pinned(model),
            "outcome" to outcome.wire,
        )

    /**
     * Once ever. Paired with [appFirstOpen], this is the activation rate — the
     * share of installs that reach a working transcript at all — obtained
     * without any per-user identity.
     */
    fun firstDictationEver() = recordOnce(TelemetryEvent.FIRST_DICTATION_EVER)

    /**
     * [model] and [quality] describe what this dictation was configured with,
     * and both are mapped rather than passed through: [TelemetryModelId.of] and
     * [TelemetryQuality.of] decide what a gateway session reports, so a call
     * site cannot attribute one to a local model it never touched.
     */
    fun dictationSucceeded(
        source: TelemetrySource,
        duration: TelemetryDurationBucket,
        model: LocalModelDescriptor?,
        quality: TranscriptionQuality?,
    ) = record(
        TelemetryEvent.DICTATION_SUCCEEDED,
        "source" to source.wire,
        "duration_bucket" to duration.wire,
        "model_id" to TelemetryModelId.of(model, source),
        "quality" to TelemetryQuality.of(quality, source).wire,
    )

    fun dictationFailed(
        stage: TelemetryStage,
        reason: TelemetryReason,
        source: TelemetrySource,
        model: LocalModelDescriptor?,
        quality: TranscriptionQuality?,
    ) = record(
        TelemetryEvent.DICTATION_FAILED,
        "stage" to stage.wire,
        "reason" to reason.wire,
        "source" to source.wire,
        "model_id" to TelemetryModelId.of(model, source),
        "quality" to TelemetryQuality.of(quality, source).wire,
    )

    // MARK: - The switch

    /**
     * Turns reporting on or off, and does the one thing the settings copy
     * promises: a final `telemetry_disabled` event goes out before the switch
     * takes effect, so the opt-out rate is knowable.
     *
     * Both directions rotate the session, so events either side of a toggle
     * cannot be stitched together. Turning it off also discards whatever was
     * still queued — an opt-out that silently delivered a backlog would be a
     * lie.
     */
    fun setEnabled(enabled: Boolean) {
        scope.launch { applyEnabled(enabled) }
    }

    internal suspend fun applyEnabled(enabled: Boolean) {
        if (enabled) {
            session.rotate()
            preferences.setEnabled(true)
            return
        }
        if (preferences.isEnabled()) {
            enqueue(TelemetryEvent.TELEMETRY_DISABLED, emptyMap())
            drain()
        }
        preferences.setEnabled(false)
        queue.clear()
        session.rotate()
    }

    // MARK: - Delivery

    /**
     * Sends what is queued, in batches of at most [TelemetryConfig.MAX_BATCH].
     *
     * Fails closed. A rejected batch is dropped, an unavailable one is put back
     * once and the flush stops — the real retry is the next flush, when the app
     * is next backgrounded. There is no scenario where telemetry retrying in a
     * tight loop is worth a milliamp, and a network failure must never surface
     * in the interface: the user did not ask for this feature to work.
     */
    suspend fun flush() {
        if (!preferences.isEnabled()) {
            queue.clear()
            return
        }
        drain()
    }

    private suspend fun drain() {
        while (!queue.isEmpty()) {
            val batch = queue.takeBatch()
            if (batch.isEmpty()) return
            val delivery = sink.send(batch)
            stats.attempted(delivery, batch.size, clock())
            when (delivery) {
                TelemetryDelivery.DELIVERED -> Unit
                TelemetryDelivery.REJECTED -> Unit
                TelemetryDelivery.UNAVAILABLE -> {
                    queue.requeue(batch)
                    return
                }
            }
        }
    }

    /**
     * One line of content-free delivery state for the "See what's sent" screen.
     *
     * Answers the question that took two wrong diagnoses to ask properly: did
     * this event ever get recorded, and did the last send actually succeed?
     */
    fun deliveryStatus(): String = stats.summary()

    /**
     * What the "See what's sent" screen renders: the literal JSON that would go
     * over the wire, nothing summarised or paraphrased.
     *
     * This is self-enforcing. If someone later adds a field to
     * [TelemetrySystemProps] or slips a property into an event, it appears here
     * in front of the user without anyone remembering to update a description.
     */
    fun pendingPayload(): String {
        val pending = queue.peekAll()
        if (pending.isEmpty()) return ""
        return pending.chunked(TelemetryConfig.MAX_BATCH).joinToString("\n\n") { batch ->
            JSONArray(batch.map { it.toJson() }).toString(2)
        }
    }

    fun pendingCount(): Int = queue.size()

    // MARK: - Internals

    private fun record(event: TelemetryEvent, vararg props: Pair<String, String>) {
        val properties = props.toMap()
        scope.launch { enqueueIfEnabled(event, properties) }
    }

    /**
     * [key] separates milestones that share an event name — one per setup step
     * — so completing the microphone step does not also mark the keyboard step
     * as already reported.
     */
    private fun recordOnce(
        event: TelemetryEvent,
        vararg props: Pair<String, String>,
        key: String? = null,
    ) {
        val properties = props.toMap()
        scope.launch {
            // The enabled check comes first, and the ordering is the whole
            // point. Claiming the milestone before it burns the claim while
            // reporting is off -- and because reporting is off by default and
            // the opt-in is asked at the *end* of setup, `app_first_open` and
            // every `setup_step_completed` would already be spent by the time
            // anyone could say yes. The activation rate this feature exists to
            // measure is `first_dictation_ever / app_first_open`, so a burnt
            // denominator makes it permanently zero.
            //
            // Claiming only while enabled means a milestone fires on its first
            // *observable* occurrence instead, which is the honest denominator:
            // "installs we were allowed to watch", not "installs".
            if (!preferences.isEnabled()) return@launch
            val milestone = listOfNotNull(event.wire, key).joinToString(":")
            if (preferences.claimMilestone(milestone)) enqueue(event, properties)
        }
    }

    private suspend fun enqueueIfEnabled(event: TelemetryEvent, props: Map<String, String>) {
        if (!preferences.isEnabled()) return
        enqueue(event, props)
    }

    private fun enqueue(event: TelemetryEvent, props: Map<String, String>) {
        queue.add(
            TelemetryRecord(
                eventName = event.wire,
                timestamp = clock(),
                sessionId = session.currentId(),
                systemProps = systemProps(),
                props = props,
            )
        )
        stats.recorded()
        scheduleFlush()
    }

    /**
     * Sends shortly after an event, coalescing anything else that arrives in the
     * same window.
     *
     * This is what actually delivers most events. A dictation from the keyboard
     * happens with no activity on screen, so the background transition
     * [TelemetryFlushScheduler] waits for never comes — without this, those
     * events sat in the queue until the process died. Superseding the previous
     * job rather than stacking one per event keeps a burst to a single request
     * — synchronised because events are recorded on `Dispatchers.Default`, and
     * two unsynchronised callers here would each leave a live job behind and
     * send the same burst twice.
     */
    @Synchronized
    private fun scheduleFlush() {
        val delayMillis = autoFlushDelayMillis ?: return
        flushJob?.cancel()
        flushJob = scope.launch {
            delay(delayMillis)
            flush()
        }
    }
}
