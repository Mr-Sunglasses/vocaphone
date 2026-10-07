package com.vocahq.vocaphone.dictation

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.vocahq.vocaphone.BuildConfig
import com.vocahq.vocaphone.accessibility.isAccessibilityServiceEnabled
import com.vocahq.vocaphone.audio.AudioCapture
import com.vocahq.vocaphone.audio.CueTiming
import com.vocahq.vocaphone.audio.CaptureFormat
import com.vocahq.vocaphone.audio.DictationTonePlayer
import com.vocahq.vocaphone.audio.MicrophoneInterruptedException
import com.vocahq.vocaphone.audio.MicrophoneInterruption
import com.vocahq.vocaphone.audio.PcmConversion
import com.vocahq.vocaphone.audio.SilentCapture
import com.vocahq.vocaphone.audio.WavWriter
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.core.DictatedTranscript
import com.vocahq.vocaphone.core.DictationFailure
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.DictationTone
import com.vocahq.vocaphone.core.MissingPermission
import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.PauseDetector
import com.vocahq.vocaphone.core.SnippetExpander
import com.vocahq.vocaphone.data.HistoryRepository
import com.vocahq.vocaphone.data.UsageStatsRepository
import com.vocahq.vocaphone.data.DiagnosticLog
import com.vocahq.vocaphone.gateway.GatewayClient
import com.vocahq.vocaphone.gateway.GatewayException
import com.vocahq.vocaphone.gateway.GatewayRecordingTransport
import com.vocahq.vocaphone.gateway.GatewayStreamingPolicy
import com.vocahq.vocaphone.gateway.GatewayUploadAudio
import com.vocahq.vocaphone.gateway.StreamingUnavailableException
import com.vocahq.vocaphone.gateway.openRecordingTransport
import com.vocahq.vocaphone.local.LocalModelManager
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.local.LocalTranscription
import com.vocahq.vocaphone.local.SherpaIncrementalSession
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import com.vocahq.vocaphone.settings.SettingsRepository
import com.vocahq.vocaphone.telemetry.Telemetry
import com.vocahq.vocaphone.telemetry.TelemetryDurationBucket
import com.vocahq.vocaphone.telemetry.TelemetryReason
import com.vocahq.vocaphone.telemetry.TelemetryStage
import com.vocahq.vocaphone.telemetry.telemetryModel
import com.vocahq.vocaphone.telemetry.telemetrySource
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Where a dictation was started from, which decides where its transcript goes. */
enum class DictationSource {
    /** The companion app's scratchpad: the transcript stays in the app. */
    COMPANION_APP,

    /**
     * The floating bubble (X builds): insert into whatever field is focused
     * at Finish, through the accessibility service.
     */
    FLOATING,

    /** The system keyboard: commit into its current InputConnection. */
    IME,
}

/**
 * Owns one dictation at a time: capture, gateway delivery, insertion, retry and
 * the state every surface renders from.
 */
class DictationController(
    private val context: Context,
    private val settings: SettingsRepository,
    private val history: HistoryRepository,
    private val diagnostics: DiagnosticLog,
    private val audioDirectory: File,
    private val localModels: LocalModelManager,
    private val telemetry: Telemetry,
    private val cues: DictationTonePlayer,
    private val usageStats: UsageStatsRepository,
    private val scope: CoroutineScope,
    /**
     * Suspends until one-time settings migration has finished.
     *
     * The retired-model migration runs in a coroutine launched from the
     * application container, while this controller is constructed
     * synchronously beside it and the keyboard can ask for a dictation as soon
     * as the process is up. Without this the first dictation after an upgrade
     * can read the pre-migration settings -- a retired model id with on-device
     * transcription still enabled -- pass the permission gate, record, and then
     * fail at `deliverLocal` on an id that is no longer in the catalog.
     *
     * Awaiting costs nothing once the migration has completed, which is every
     * launch but the first after an upgrade.
     */
    private val awaitSettingsMigration: suspend () -> Unit = {},
) {
    private val _state = MutableStateFlow(DictationState())
    val state: StateFlow<DictationState> = _state.asStateFlow()

    /** Set by the IME while the keyboard service is connected. */
    @Volatile
    var imeInserter: TranscriptInserter? = null

    /** Set by the accessibility service while it is connected (X builds). */
    @Volatile
    var floatingInserter: TranscriptInserter? = null

    private var lastInsertion: AppliedInsertion? = null

    val canUndo: Boolean get() = lastInsertion != null

    private var pipeline: Job? = null
    private var startupRepairSignal: CompletableDeferred<Unit>? = null
    private var capture: AudioCapture? = null

    /**
     * The WAV scratch file and its writer while a dictation is recording.
     * `runDictation` closes and deletes them on every path it reaches itself;
     * these references exist so a cancel that kills the pipeline before it
     * reaches that cleanup does not leave the recording behind.
     */
    private var liveWriter: WavWriter? = null
    private var liveWavFile: File? = null

    /**
     * The in-flight session's recording and id, kept past the scratch window
     * so a recovery path can tell an orphaned file (no history record: delete)
     * from retry material (a record holds it: keep).
     */
    private var sessionWavFile: File? = null
    private var activeSessionId: UUID? = null

    /**
     * Serializes pipeline ownership: a new session assigns `pipeline` and
     * advances `generation` under it, and a recovery path checks ownership
     * and resets under it, so a dead job's cleanup cannot interpose into the
     * session that replaced it.
     */
    private val sessionLock = Any()

    @Volatile
    private var activeSource: DictationSource? = null

    @Volatile
    private var finishSignal = CompletableDeferred<Unit>()

    @Volatile
    private var cancelRequested = false

    /**
     * Which dictation owns [state]. `fail` finishes its history write under
     * `NonCancellable`, so a cancel — or the dictation the user starts straight
     * after one — can land while a failure is still being reported. The late
     * write then put a FAILED phase on top of a session that was recording
     * perfectly well. Every start, retry and reset takes the next generation,
     * and a write from an older one is dropped.
     */
    private val generation = AtomicInteger()

    /**
     * Starts and retries waiting behind an unwinding pipeline. The count is
     * held from queueing until their claim attempt runs, so a watcher can
     * tell "no session" from "the next one just hasn't taken the slot yet" —
     * the gap where a foreground service would otherwise stop.
     */
    private val queuedStarts = AtomicInteger()

    /**
     * Bumped on every session transition the dictation service can care
     * about: a claim, a queue add or drain, and a pipeline ending. The
     * service's observer parks on it between sessions.
     */
    internal val sessionVersion = MutableStateFlow(0L)

    private fun noteSessionChanged() {
        sessionVersion.update { it + 1 }
    }

    /**
     * True while any dictation owns or is about to own the pipeline slot:
     * running, queued behind the current one, or holding a busy phase.
     */
    internal fun sessionInFlight(): Boolean =
        pipeline?.isActive == true ||
            queuedStarts.get() > 0 ||
            _state.value.phase.isBusy

    /**
     * True while the pipeline's only remaining work is the tail of an attempt
     * that resolved without recording — e.g. following a model download — and
     * no queued session waits behind it. Read atomically under the session
     * lock so a queued claim cannot split "old repair completed" from "queue
     * drained": the queue count is held through the claim, and the claim
     * swaps the repair signal inside this same lock.
     */
    internal fun repairSettledWithoutQueue(): Boolean = synchronized(sessionLock) {
        startupRepairSignal?.isCompleted == true &&
            queuedStarts.get() == 0 &&
            pipeline?.isActive == true
    }

    /**
     * Runs [queued] once [after] finishes. The queue count is held through
     * the claim attempt — not just the wait — so [sessionInFlight] never
     * reads "idle" while a successor is between the old job's end and the
     * new session's first phase.
     */
    private fun queueSessionStart(after: Job?, queued: () -> Unit) {
        queuedStarts.incrementAndGet()
        noteSessionChanged()
        scope.launch(Dispatchers.IO) {
            try {
                after?.join()
                queued()
            } finally {
                queuedStarts.decrementAndGet()
                noteSessionChanged()
            }
        }
    }

    /**
     * How long the last completed capture ran, for the telemetry duration
     * bucket. Written once the WAV is closed and read at delivery, because the
     * writer is scoped to `runDictation` and the outcome is reported from
     * `deliver`/`fail` further down.
     */
    /**
     * Cleared on retry, because a retry re-transcribes a stored WAV without
     * recording anything: the previous live capture's length would otherwise be
     * reported as this dictation's, and after a process restart a retried
     * 90-second dictation would report `under_10s`. Null means "no duration to
     * report", and the outcome is sent without a bucket rather than with a
     * wrong one.
     */
    @Volatile
    private var lastRecordingMillis: Long? = null

    /** Last speech-source settings seen; see the collector in `init`. */
    private var repairInputs: RepairInputs? = null

    init {
        scope.launch {
            state
                .map { it.phase }
                .distinctUntilChanged()
                .collect { phase ->
                    diagnostics.recordState(phase.name, activeSource?.name)
                }
        }
        // A repair state is an answer about the settings it was worked out
        // from, and nothing else ever cleared it: the keyboard mic opens the
        // app while one is showing, it does not try again. So someone who hit
        // "Voice model needed" on this phone, then switched to their gateway,
        // was still told to download a model, and every tap of the mic sent
        // them to Models. Drop the repair -- and any download it is following
        // -- once the speech source it was about has changed; the next tap
        // checks again against what is set now.
        scope.launch {
            settings.settings
                .map(::RepairInputs)
                .distinctUntilChanged()
                .collect { inputs ->
                    val stale = repairOutlived(_state.value.phase, repairInputs, inputs)
                    repairInputs = inputs
                    if (stale) {
                        pipeline?.cancel()
                        reset()
                    }
                }
        }
    }

    /**
     * Starts a dictation unless one is already running. Missing permissions or
     * gateway settings surface as a repair state rather than a failure.
     */
    fun start(source: DictationSource) {
        val inFlight = pipeline
        if (inFlight?.isActive == true) {
            // A tap while a session is still unwinding used to be dropped
            // silently; queue it so the dictation the user asked for runs
            // once the pipeline frees the slot.
            queueSessionStart(inFlight) { start(source) }
            return
        }
        diagnostics.recordAction("start", source.name)
        var generation = -1
        var lostSlot = false
        synchronized(sessionLock) {
            // The slot check repeats inside the claim: starts queued behind
            // the same finishing pipeline can all see it idle before any of
            // them launches. Whoever arrives second queues behind the winner
            // rather than overwriting a session that is no longer theirs.
            if (pipeline?.isActive == true) {
                lostSlot = true
            } else {
                activeSource = source
                finishSignal = CompletableDeferred()
                cancelRequested = false
                val repairSignal = CompletableDeferred<Unit>()
                startupRepairSignal = repairSignal
                generation = nextGeneration()
                pipeline = scope.launch {
                noteSessionChanged()
            awaitSettingsMigration()
            val configuration = settings.current()
            val missing = missingPermissions(configuration)
            if (missing.isNotEmpty()) {
                diagnostics.recordError("setup", source.name)
                _state.value = DictationState(
                    phase = DictationPhase.PERMISSION_REPAIR,
                    missingPermissions = missing,
                )
                repairSignal.complete(Unit)
                return@launch
            }
            val token = if (configuration.localTranscriptionEnabled) null else settings.token()
            if (!configuration.localTranscriptionEnabled && token.isNullOrEmpty()) {
                diagnostics.recordError("setup", source.name)
                _state.value = DictationState(
                    phase = DictationPhase.PERMISSION_REPAIR,
                    missingPermissions = setOf(MissingPermission.GATEWAY_NOT_CONFIGURED),
                )
                repairSignal.complete(Unit)
                return@launch
            }
            if (configuration.localTranscriptionEnabled) {
                val models = localModels.state.value
                val repair = modelRepair(
                    configuredId = configuration.localModelId,
                    configuredPresent = !localModelUnavailable(configuration),
                    models = models,
                )
                if (repair != null) {
                    diagnostics.recordError("setup", source.name)
                    _state.value = DictationState(
                        phase = DictationPhase.PERMISSION_REPAIR,
                        missingPermissions = setOf(repair),
                        modelDownloadProgress = models.progress.takeIf { repair == MissingPermission.MODEL_DOWNLOADING },
                    )
                    // No recording will start in this attempt. Model progress
                    // keeps the pipeline alive, but needs no microphone service.
                    repairSignal.complete(Unit)
                    val target = models.pendingUse ?: models.downloading
                    if (target != null &&
                        (repair == MissingPermission.MODEL_DOWNLOADING || repair == MissingPermission.MODEL_PREPARING)
                    ) {
                        followDownload(target = target)
                    }
                    return@launch
                }
            }
            runDictation(source, configuration, token, UUID.randomUUID(), generation)
            }
            }
        }
        if (lostSlot) {
            queueSessionStart(pipeline) { start(source) }
            return
        }
        lastPipelineSettled(pipeline, generation)
    }

    /**
     * The unwind inside a pipeline is obliged to leave the phase non-busy,
     * but nothing makes it: a crash or a hard cancel escapes with whatever
     * phase was on screen, and every later cancel then joins an already-dead
     * job and does nothing — a wedge that logs `action=cancel` forever. The
     * pipeline's own exit is the last place that can let a busy phase past,
     * so the settlement is checked here rather than trusted to every return.
     */
    private fun lastPipelineSettled(job: Job?, generation: Int) {
        if (job == null) return
        val completionCause = AtomicReference<Throwable?>()
        job.invokeOnCompletion { completionCause.set(it) }
        scope.launch(Dispatchers.IO) {
            job.join()
            // A failed job's cause is the crash the unwind never converted
            // into a state; a plain cancel leaves it null.
            settleBusyPipeline(job, generation, completionCause.get())
            noteSessionChanged()
        }
    }

    /**
     * Ends a session whose pipeline left a busy phase behind, however it
     * exited. Three recoveries happen as one operation under [sessionLock],
     * checked against the job and generation that asked: the microphone is
     * stopped (a crashed unwind can leave `AudioCapture`'s read thread
     * holding it), a recording with no history record is deleted while retry
     * material is kept, and the state is reset. Ownership and the reset are
     * deliberately one guarded block — a new dictation must never be settled
     * by the session it replaced.
     */
    private suspend fun settleBusyPipeline(job: Job?, generation: Int, cause: Throwable? = null) {
        // A bounded wait first: a NonCancellable history write outlives
        // cancellation, and the orphan check below has to read a history that
        // has finished resolving.
        if (job != null) {
            withTimeoutOrNull(SETTLE_JOIN_MILLIS) { job.join() }
        }
        val orphan = run {
            val sessionId = activeSessionId
            val wavFile = sessionWavFile
            // A live job can still be inside a NonCancellable history write:
            // its record does not exist yet and the WAV is that write's own
            // file, not an orphan. Only a settled pipeline leaves a recording
            // history will never claim.
            if (sessionId != null && wavFile != null &&
                (job == null || job.isCompleted) &&
                this@DictationController.generation.get() == generation &&
                history.find(sessionId.toString())?.audioPath == null
            ) {
                wavFile
            } else {
                null
            }
        }
        // Capture stop runs outside the lock: it can hold its monitor for
        // seconds while the read thread drains, and a new session taking the
        // lock to start must not wait behind it. While the generation still
        // matches, the capture on the field is this session's to stop.
        if (this@DictationController.generation.get() == generation) {
            runCatching { capture?.stop() }
        }
        val wavInFlight = sessionWavFile
        val wavSession = activeSessionId
        if (job != null && !job.isCompleted && wavInFlight != null && wavSession != null) {
            // The pipeline is still finishing a NonCancellable history write:
            // its record does not exist yet and the WAV is that write's own
            // file — never deleted mid-write. Sweep once the job truly ends;
            // clearing the session refs below is then safe because this
            // trailing pass owns the decision.
            scope.launch(Dispatchers.IO) {
                job.join()
                if (history.find(wavSession.toString())?.audioPath == null) {
                    wavInFlight.delete()
                }
            }
        }
        synchronized(sessionLock) {
            if (pipeline !== job ||
                this@DictationController.generation.get() != generation ||
                !_state.value.phase.isBusy
            ) {
                return
            }
            diagnostics.recordError(
                "pipeline_settled_busy",
                cause?.javaClass?.simpleName ?: activeSource?.name,
            )
            discardLiveRecording(generation)
            orphan?.delete()
            sessionWavFile = null
            activeSessionId = null
            reset()
        }
    }

    /** Exact pipeline lifetime; phase updates can be conflated before the service sees them. */
    internal val activeJob: Job? get() = pipeline

    /** Attempt-specific: unlike state, this cannot contain a prior start's repair. */
    internal val startupRepair: Deferred<Unit>? get() = startupRepairSignal

    fun finish() {
        finishSignal.complete(Unit)
        diagnostics.recordTiming("finish_requested", activeSource?.name)
    }

    fun cancel() {
        diagnostics.recordAction("cancel", activeSource?.name)
        cancelRequested = true
        finishSignal.complete(Unit)
        val job = pipeline
        val captureToStop = capture
        val generation = this.generation.get()
        val phase = _state.value.phase
        if (phase == DictationPhase.LISTENING && job != null) {
            // The watchdog is armed before anything that can block, because
            // the teardown below runs AudioCapture.stop(), which is
            // synchronized and joins the read thread: a wedge there is exactly
            // the cancel that must not be able to strand the unwind. IO rather
            // than the controller's Default pool, so blocked pipeline work
            // cannot starve it of a thread either.
            scope.launch(Dispatchers.IO) {
                // LISTENING unwinds itself: the completed signal lets the
                // pipeline close and discard its WAV on its own thread, then
                // it resets. That unwind crosses several suspend points, so a
                // transport or writer that never answers would leave
                // "Listening" on screen with no way out. The bound is on the
                // wait, not the recovery: whatever the join leaves — a still
                // running job or an already-dead one — a busy phase this
                // session owns is ended here.
                withTimeoutOrNull(CANCEL_UNWIND_MILLIS) { job.join() }
                if (pipeline === job && _state.value.phase.isBusy) {
                    job.cancel()
                    settleBusyPipeline(job, generation)
                }
            }
        }
        // The rest of the teardown also moves off the caller's thread: cancel
        // is called from service handlers and the bubble, and none of them may
        // sit inside a blocking AudioRecord stop. A newer dictation can legally
        // have taken pipeline/capture by the time this runs, so both are read
        // into locals up front rather than re-read inside the coroutine.
        scope.launch(Dispatchers.IO) {
            // Stop a blocked upload/setup child immediately. Keep the
            // recording parent alive long enough to close and discard its
            // local WAV below.
            job?.children?.forEach { it.cancel() }
            captureToStop?.stop()
            if (phase != DictationPhase.LISTENING && job != null) {
                job.cancel()
                if (phase.isBusy) {
                    settleBusyPipeline(job, generation)
                } else {
                    // A dismissed failure or idle can still be cancelled;
                    // only the generation guard decides it is ours to clear.
                    synchronized(sessionLock) {
                        if (this@DictationController.generation.get() == generation) {
                            reset()
                        }
                    }
                }
            }
        }
    }

    /**
     * Last-resort cleanup for a pipeline that never reached its own writer
     * close and WAV delete. Two guards decide ownership before anything is
     * touched: the cancelling generation, so a stale cancel cannot close or
     * delete a fresh dictation's recording, and the live references
     * themselves — they exist only while a *recorded* session's WAV is still
     * scratch (set when the file is created, cleared the moment the writer
     * closes and custody passes to the pipeline's own delete-or-keep logic).
     * A retry's WAV is history audio, never scratch, so this is a no-op for it.
     */
    private fun discardLiveRecording(generation: Int) {
        if (this.generation.get() != generation) return
        runCatching { liveWriter?.close() }
        liveWavFile?.delete()
        liveWriter = null
        liveWavFile = null
    }

    /**
     * Re-sends audio that was preserved for a recoverable failure.
     *
     * [source] is the surface the retry was initiated from, which decides where
     * the transcript is delivered: the bubble retries a floating dictation into
     * the focused field, while a History retry keeps it in the companion app.
     */
    fun retry(sessionId: String, source: DictationSource = DictationSource.COMPANION_APP) {
        val inFlight = pipeline
        if (inFlight?.isActive == true) {
            // A busy pipeline used to drop this request silently, which is
            // exactly what happens when a retry follows a cancel that is
            // still unwinding. Queue it behind that job instead.
            queueSessionStart(inFlight) { retryQueued(sessionId, source) }
            return
        }
        retryQueued(sessionId, source)
    }

    private fun retryQueued(sessionId: String, source: DictationSource) {
        var generation = -1
        var lostSlot = false
        synchronized(sessionLock) {
            // Same claim as start(): the busy check is repeated under the
            // lock, and a retry that loses queues behind the session that
            // won instead of being dropped.
            if (pipeline?.isActive == true) {
                lostSlot = true
            } else {
                startupRepairSignal = null
                activeSource = source
                // Nothing is recorded on this path, so the previous capture's
                // length is not this dictation's.
                lastRecordingMillis = null
                generation = nextGeneration()
                pipeline = scope.launch {
                noteSessionChanged()
            val record = history.find(sessionId) ?: return@launch
            val audio = record.audioPath?.let(::File)
            if (audio == null || !audio.exists()) {
                val id = UUID.fromString(sessionId)
                _state.value = _state.value.copy(
                    sessionId = id,
                    phase = DictationPhase.FAILED,
                    failure = DictationFailure(
                        "audio_expired",
                        "The recording for this dictation is no longer stored.",
                        recoverable = false,
                    ),
                )
                lingerThenIdle(id, DictationPhase.FAILED, FAILED_LINGER_MILLIS)
                return@launch
            }
            // The same two guards as `start`. A recording kept across an upgrade
            // can be retried before the retired-model migration has run, and a
            // retry against a model that is not on the phone fails again every
            // time -- recoverably, so it could be retried forever.
            awaitSettingsMigration()
            val configuration = settings.current()
            if (localModelUnavailable(configuration)) {
                _state.value = DictationState(
                    phase = DictationPhase.PERMISSION_REPAIR,
                    missingPermissions = setOf(MissingPermission.LOCAL_MODEL_UNAVAILABLE),
                )
                return@launch
            }
            _state.value = DictationState(
                sessionId = UUID.fromString(sessionId),
                phase = DictationPhase.UPLOADING,
                language = configuration.effectiveLanguage,
                style = configuration.style,
            )
            if (configuration.localTranscriptionEnabled) {
                val modelID = configuration.localModelId.takeIf { it.isNotEmpty() }
                modelID?.let {
                    localModels.beginUse()
                    localModels.warm(
                        it,
                        record.language,
                        configuration.transcriptionQuality,
                        configuration.translationTarget,
                    )
                }
                try {
                    deliverLocal(
                        sessionId = UUID.fromString(sessionId),
                        wavFile = audio,
                        language = record.language,
                        configuration = configuration,
                        source = source,
                        generation = generation,
                    )
                } finally {
                    if (modelID != null) {
                        localModels.endUse(configuration.modelIdleTimeout.delayMs)
                    }
                }
            } else {
                val token = settings.token() ?: return@launch
                deliverBatch(
                    client = gatewayClient(configuration.gatewayUrl, token),
                    sessionId = UUID.fromString(sessionId),
                    wavFile = audio,
                    language = record.language,
                    style = record.style,
                    configuration = configuration,
                    source = source,
                    generation = generation,
                )
            }
            }
            }
        }
        if (lostSlot) {
            queueSessionStart(pipeline) { retryQueued(sessionId, source) }
            return
        }
        lastPipelineSettled(pipeline, generation)
    }

    fun clearTransient() {
        if (!_state.value.phase.isBusy) reset()
    }

    /**
     * The microphone foreground service could not be started, so [start] was
     * never reached and nothing was recorded. Without this the tap simply did
     * nothing: the keyboard kept saying it was ready and the user was left to
     * guess. Shown as an ordinary failure that clears itself like any other,
     * and nothing goes to history because there is no audio to retry.
     */
    fun microphoneServiceRefused(source: DictationSource) {
        diagnostics.recordError(MicrophoneForegroundPromote.ERROR_CATEGORY, source.name)
        val sessionId = UUID.randomUUID()
        synchronized(sessionLock) {
            // A session that did get going owns the state; do not paint a
            // failure over it.
            val failed = MicrophoneForegroundPromote.refusedState(
                current = _state.value,
                sessionId = sessionId,
                pipelineActive = pipeline?.isActive == true,
            ) ?: return
            nextGeneration()
            _state.value = failed
        }
        lingerThenIdle(sessionId, DictationPhase.FAILED, FAILED_LINGER_MILLIS)
    }

    /** Removes the last insertion when the exact text is still where it was put. */
    suspend fun undoLast(): Boolean {
        val insertion = lastInsertion ?: return false
        val removed = floatingInserter?.undo(insertion) ?: false
        if (removed) lastInsertion = null
        return removed
    }

    fun missingPermissions(
        configuration: VocaPhoneSettings,
        source: DictationSource = activeSource ?: DictationSource.COMPANION_APP,
    ): Set<MissingPermission> = buildSet {
        if (!hasPermission(Manifest.permission.RECORD_AUDIO)) add(MissingPermission.MICROPHONE)
        if (!hasPermission(Manifest.permission.POST_NOTIFICATIONS)) add(MissingPermission.NOTIFICATIONS)
        if (BuildConfig.FLOATING_INPUT && source == DictationSource.FLOATING) {
            if (!android.provider.Settings.canDrawOverlays(context)) add(MissingPermission.OVERLAY)
            if (!context.isAccessibilityServiceEnabled()) add(MissingPermission.ACCESSIBILITY)
        }
        if (!configuration.isConfigured && !configuration.localTranscriptionEnabled) {
            add(MissingPermission.GATEWAY_NOT_CONFIGURED)
        }
    }

    private fun localModelUnavailable(configuration: VocaPhoneSettings): Boolean =
        configuration.localModelMissing ||
            (configuration.localTranscriptionEnabled &&
                !localModels.modelFilesPresent(configuration.localModelId))

    private fun hasPermission(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    // ------------------------------------------------------------- pipeline

    // `start` refuses to reach here until RECORD_AUDIO has been granted.
    @SuppressLint("MissingPermission")
    private suspend fun runDictation(
        source: DictationSource,
        configuration: VocaPhoneSettings,
        token: String?,
        sessionId: UUID,
        generation: Int,
    ) {
        audioDirectory.mkdirs()
        val wavFile = File(audioDirectory, "$sessionId.wav")
        liveWavFile = wavFile
        // The pair stays set past the scratch window: a settled-busy recovery
        // uses it to tell a cancelled orphan (delete) from audio history is
        // holding for retry (keep).
        sessionWavFile = wavFile
        activeSessionId = sessionId
        val client = token?.let { gatewayClient(configuration.gatewayUrl, it) }
        val sessionFinishSignal = finishSignal
        val frames = Channel<ShortArray>(capacity = FILE_FRAME_BUFFER_CAPACITY)
        val selectedLocalModelID = configuration.localModelId.takeIf { it.isNotEmpty() }
        if (configuration.localTranscriptionEnabled) {
            selectedLocalModelID?.let { modelID ->
                localModels.beginUse()
                // Load weights while the mic is already capturing. Whisper used
                // to wait until Finish, so the first dictation after a cold
                // start spent seconds on "Transcribing" before the decoder ran.
                localModels.warm(
                    modelID,
                    configuration.effectiveLanguage.wireValue,
                    configuration.transcriptionQuality,
                    configuration.translationTarget,
                )
            }
        }
        var streamPump: Job? = null
        val streamReference = AtomicReference<GatewayRecordingTransport?>()
        try {
        val incrementalSession = if (configuration.localTranscriptionEnabled) {
            selectedLocalModelID?.let { modelID ->
                localModels.startIncrementalSession(
                    modelID = modelID,
                    language = configuration.effectiveLanguage.wireValue,
                    scope = scope,
                    quality = configuration.transcriptionQuality,
                    translateTo = configuration.translationTarget,
                )
            }
        } else {
            null
        }
        val incrementalReference = AtomicReference<SherpaIncrementalSession?>(incrementalSession)
        val incrementalFallback = AtomicBoolean(false)
        if (incrementalSession != null) {
            diagnostics.recordTiming("local_incremental_started", source.name)
        }
        val gatewayAudio = GatewayStreamingPolicy.shouldSendGatewayAudio(
            localTranscriptionEnabled = configuration.localTranscriptionEnabled,
            gatewayConfigured = client != null,
        )
        val shouldAttemptStreaming = gatewayAudio && GatewayStreamingPolicy.shouldAttemptStreaming(
            supported = configuration.lastStreamingSupported,
            checkedAtMillis = configuration.lastEngineCheckedAtMillis,
        )
        val streamFrames = if (gatewayAudio) {
            Channel<ShortArray>(capacity = STREAM_FRAME_BUFFER_CAPACITY)
        } else {
            null
        }
        val writer = WavWriter(wavFile)
        liveWriter = writer
        val captureError = AtomicReference<Throwable?>()
        val streamAcceptingFrames = AtomicBoolean(streamFrames != null)
        val droppedStreamFrames = AtomicInteger()
        val batchFallbackRecorded = AtomicBoolean()
        val cueQuietAt = AtomicLong(0L)
        val cueOverlapSamples = AtomicInteger()
        val cuePlayed = AtomicBoolean(false)
        fun recordBatchFallback() {
            if (batchFallbackRecorded.compareAndSet(false, true)) {
                diagnostics.recordTiming("batch_fallback", source.name)
            }
        }

        val recorder = AudioCapture(
            context = context,
            preference = configuration.microphone,
            onFrame = { samples, count ->
                // Captured speech is authoritative. The old cue gate threw away
                // every frame under the start tone, including the first word
                // when a user quite reasonably began speaking on that tone.
                // A recognizer can ignore a short non-speech cue; it cannot
                // reconstruct microphone samples the app deleted.
                val frame = samples.copyOf(count)
                if (SystemClock.elapsedRealtime() <= cueQuietAt.get()) {
                    cueOverlapSamples.addAndGet(count)
                }
                if (frames.trySend(frame).isFailure) {
                    captureError.compareAndSet(
                        null,
                        IllegalStateException("Audio processing could not keep up."),
                    )
                    sessionFinishSignal.complete(Unit)
                }
                // The WAV keeps the cue for the authoritative path, but the
                // latency candidate starts after it just like the old gate did.
                if (SystemClock.elapsedRealtime() > cueQuietAt.get()) {
                    incrementalReference.get()?.let { session ->
                        if (!session.offer(frame) && incrementalReference.compareAndSet(session, null)) {
                            incrementalFallback.set(true)
                            session.cancel()
                        }
                    }
                }
                if (streamAcceptingFrames.get() &&
                    streamFrames?.trySend(frame)?.isFailure == true
                ) {
                    droppedStreamFrames.incrementAndGet()
                    streamAcceptingFrames.set(false)
                    streamFrames.cancel()
                }
            },
            onError = { error ->
                captureError.compareAndSet(null, error)
                sessionFinishSignal.complete(Unit)
            },
        )
        capture = recorder
        // The cue still overlaps AudioRecord warm-up so it adds little startup
        // latency, but captured frames are retained. Waiting only controls the
        // listening state and haptic; it no longer controls audio ownership.
        val cueStartedAt = SystemClock.elapsedRealtime()
        cueQuietAt.set(cues.startCue(configuration.dictationTone))
        cuePlayed.set(cueQuietAt.get() > cueStartedAt)
        if (!recorder.start()) {
            announceStopped(configuration.dictationTone)
            incrementalReference.getAndSet(null)?.cancel()
            frames.close()
            streamFrames?.close()
            writer.close()
            wavFile.delete()
            // Nothing was captured, so there is nothing for Retry to re-send.
            // The user's next step is to start again, not to resend silence.
            fail(
                sessionId,
                GatewayException(
                    "microphone_unavailable",
                    captureError.get()?.message ?: "The microphone is not available right now.",
                    recoverable = false,
                ),
                wavFile = null,
                configuration = configuration,
                generation = generation,
            )
            return
        }

        // Whatever the warm-up did not already cover. The haptic goes here
        // rather than with the cue because it is the "speak now" signal, and
        // now is when speaking starts being recorded.
        delay(CueTiming.waitMillis(cueQuietAt.get(), SystemClock.elapsedRealtime()))
        cues.haptic()
        val cueAnalysisStartSample = CueTiming.conditioningStartSample(
            cueOverlapSamples = cueOverlapSamples.get(),
            frameSamples = CaptureFormat.SAMPLE_RATE / 10,
            cuePlayed = cuePlayed.get(),
        )

        val captureStartedAt = SystemClock.elapsedRealtime()
        _state.value = DictationState(
            sessionId = sessionId,
            phase = DictationPhase.LISTENING,
            language = configuration.effectiveLanguage,
            style = configuration.style,
            startedAtElapsedMillis = captureStartedAt,
        )

        // Frames are drained off the capture thread: file writes and socket sends
        // must never stall the AudioRecord read loop.
        val heardSomething = AtomicBoolean(false)
        val pauseDetector = if (configuration.stopAfterPause) PauseDetector() else null
        val drain = scope.launch(Dispatchers.IO) {
            for (frame in frames) {
                writer.write(frame, frame.size)
                // Only until the first real sample arrives: past that the
                // recording is known to contain audio and the scan is waste.
                if (!heardSomething.get() &&
                    SilentCapture.heardSomething(PcmConversion.peak(frame, frame.size))
                ) {
                    heardSomething.set(true)
                }
                val level = PcmConversion.level(frame, frame.size)
                // Stop after a pause: the same finish a tap on Stop sends.
                // `finish` completes a signal, so a second call is harmless.
                if (pauseDetector?.observe(level, frame.size.toDouble() / CaptureFormat.SAMPLE_RATE) == true &&
                    _state.value.phase == DictationPhase.LISTENING
                ) {
                    diagnostics.recordAction("stop_after_pause", source.name)
                    finish()
                }
                _state.update { current ->
                    if (current.phase != DictationPhase.LISTENING) {
                        current
                    } else {
                        current.copy(
                            level = level,
                            recordedMillis = writer.durationMillis,
                            partialTranscript = streamReference.get()?.latestPartial()
                                ?: current.partialTranscript,
                            inputRouteLabel = recorder.currentRouteLabel() ?: current.inputRouteLabel,
                        )
                    }
                }
            }
        }

        streamPump = streamFrames?.let { channel ->
            // A child of this dictation, not the service's long-lived scope:
            // cancelling finalization must close the active HTTP/socket call.
            CoroutineScope(currentCoroutineContext()).launch(Dispatchers.IO) {
                var candidate: GatewayRecordingTransport? = null
                var ready = false
                try {
                    diagnostics.recordTiming("stream_handshake_started", source.name)
                    val opened = client!!.openRecordingTransport(
                        sessionId = sessionId,
                        language = configuration.effectiveLanguage.wireValue,
                        style = configuration.style.wireValue,
                        sampleRate = CaptureFormat.SAMPLE_RATE,
                        attemptStreaming = shouldAttemptStreaming,
                        onUploadFinished = { markGatewayTranscribing(sessionId, source, generation) },
                    )
                    candidate = opened
                    if (!currentCoroutineContext().isActive ||
                        this@DictationController.generation.get() != generation
                    ) return@launch
                    ready = true
                    streamReference.set(opened)
                    diagnostics.recordTiming(if (opened.incremental) "stream_ready" else "upload_started", source.name)
                    _state.update {
                        if (it.sessionId == sessionId) it.copy(streaming = opened.incremental) else it
                    }

                    for (frame in channel) {
                        if (!opened.sendFrames(frame)) {
                            ready = false
                            droppedStreamFrames.incrementAndGet()
                            streamAcceptingFrames.set(false)
                            break
                        }
                    }
                } catch (error: CancellationException) {
                    ready = false
                    throw error
                } catch (_: Exception) {
                    ready = false
                    streamAcceptingFrames.set(false)
                    channel.cancel()
                    recordBatchFallback()
                } finally {
                    if (!ready || !currentCoroutineContext().isActive) {
                        candidate?.cancel()
                        streamReference.compareAndSet(candidate, null)
                    }
                }
            }
        }
        if (gatewayAudio && streamFrames == null) recordBatchFallback()

        awaitFinish(sessionFinishSignal)
        recorder.stop()
        announceStopped(configuration.dictationTone)
        diagnostics.recordTiming("capture_stopped", source.name)
        capture = null
        frames.close()
        streamAcceptingFrames.set(false)
        streamFrames?.close()
        drain.join()
        writer.close()
        // Past this point the file is never scratch again: every remaining
        // path either deletes it itself or hands it to history for retry, so
        // the discard-on-cancel references stop tracking it here.
        liveWriter = null
        liveWavFile = null
        lastRecordingMillis = writer.durationMillis

        var stream = streamReference.get()
        if (stream == null) {
            streamPump?.cancel()
            streamPump?.join()
            recordBatchFallback()
        } else {
            streamPump?.join()
            stream = streamReference.get()
        }

        if (cancelRequested) {
            incrementalReference.getAndSet(null)?.cancel()
            stream?.cancel()
            wavFile.delete()
            reset()
            return
        }

        captureError.get()?.let { error ->
            diagnostics.recordError(audioErrorCategory(error), source.name)
            // Another app taking the microphone does not invalidate the audio
            // recorded before it did. A sentence the user already finished
            // saying is transcribed rather than thrown away; only a capture
            // that produced nothing usable is reported as a failure.
            val salvageable = error is MicrophoneInterruptedException &&
                heardSomething.get() &&
                writer.durationMillis >= MINIMUM_RECORDING_MILLIS
            if (!salvageable) {
                incrementalReference.getAndSet(null)?.cancel()
                stream?.cancel()
                wavFile.delete()
                fail(
                    sessionId,
                    GatewayException(
                        "audio_interrupted",
                        error.message ?: "Microphone access was interrupted. Try again.",
                        recoverable = false,
                    ),
                    wavFile = null,
                    configuration = configuration,
                    generation = generation,
                )
                return
            }
        }

        _state.update { it.copy(phase = DictationPhase.FINALIZING, level = 0f) }

        if (writer.durationMillis < MINIMUM_RECORDING_MILLIS) {
            incrementalReference.getAndSet(null)?.cancel()
            stream?.cancel()
            wavFile.delete()
            // A tap that captured nothing is not a failure the user has to
            // dismiss. The next mic tap should start a fresh dictation.
            if (this.generation.get() == generation) reset()
            return
        }

        // A recording of exact digital zeros is what Android gives an app whose
        // microphone another app holds. Transcribing it would spend the wait to
        // report an empty transcript, which says nothing the user can act on.
        if (!heardSomething.get()) {
            incrementalReference.getAndSet(null)?.cancel()
            stream?.cancel()
            wavFile.delete()
            fail(
                sessionId,
                GatewayException(
                    "microphone_silenced",
                    "Another app was using the microphone, so VocaPhone recorded silence. " +
                        "Stop that recording and try again.",
                    recoverable = false,
                ),
                wavFile = null,
                configuration = configuration,
                generation = generation,
            )
            return
        }

        if (configuration.localTranscriptionEnabled) {
            val session = incrementalReference.getAndSet(null)
            var preparedTranscript: LocalTranscription? = null
            var timingRecorded = false
            if (session != null) {
                _state.update { it.copy(phase = DictationPhase.TRANSCRIBING, streaming = false) }
                diagnostics.recordTiming("local_transcription_started", source.name)
                timingRecorded = true
                try {
                    val incremental = session.finish()
                    if (incremental.isSafe) {
                        preparedTranscript = LocalTranscription(
                            incremental.transcript.text,
                            incremental.transcript.language,
                        )
                        diagnostics.recordTiming("local_incremental_ready", source.name)
                    } else {
                        if (incremental.droppedAudibleChunk) {
                            diagnostics.recordTiming("local_incremental_dropped_chunk", source.name)
                        }
                        if (incremental.conditioningChanged) {
                            diagnostics.recordTiming("local_incremental_unstable_gain", source.name)
                        }
                        incrementalFallback.set(true)
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Throwable) {
                    incrementalFallback.set(true)
                }
            }
            if (incrementalSession != null && incrementalFallback.get()) {
                diagnostics.recordTiming("local_incremental_fallback", source.name)
            }
            deliverLocal(
                sessionId = sessionId,
                wavFile = wavFile,
                language = configuration.effectiveLanguage.wireValue,
                configuration = configuration,
                source = source,
                generation = generation,
                conditioningStartSample = cueAnalysisStartSample,
                preparedTranscript = preparedTranscript,
                transcriptionTimingRecorded = timingRecorded,
            )
            return
        }

        if (stream != null && droppedStreamFrames.get() == 0) {
            _state.update { it.copy(phase = DictationPhase.TRANSCRIBING) }
            val transcript = try {
                if (!stream.incremental) {
                    _state.update { it.copy(phase = DictationPhase.UPLOADING) }
                    stream.finishUpload()
                }
                if (stream.incremental) diagnostics.recordTiming("transcription_started", source.name)
                stream.finish()
            } catch (error: CancellationException) {
                throw error
            } catch (_: StreamingUnavailableException) {
                recordBatchFallback()
                null
            } catch (error: GatewayException) {
                if (stream.incremental && !error.recoverable) {
                    wavFile.delete()
                    fail(sessionId, error, wavFile = null, configuration = configuration, generation = generation)
                    return
                }
                recordBatchFallback()
                null
            } catch (_: Exception) {
                recordBatchFallback()
                null
            }
            // The gateway has already applied the requested writing style to
            // streamed output. Local inference is styled in deliverLocal below;
            // applying it here would style gateway text twice. It has not
            // repaired anything, though — that stage only exists on the phone.
            val cleaned = DictatedTranscript.finished(
                transcript,
                style = configuration.style,
                // Only repair reads this on a gateway route — the style is
                // already applied — but a German transcript keeps its "um"
                // only if this stage is told the language.
                language = configuration.effectiveLanguage.wireValue,
                styledUpstream = true,
                repairSpeech = configuration.repairSpeech,
                numbersAsDigits = configuration.numbersAsDigits,
                spokenEmoji = configuration.spokenEmoji,
                snippets = configuration.snippets,
                vocabulary = CustomVocabulary.terms(configuration.whisperVocabulary),
                isDictionaryWord = ::isEnglishWord,
            )
            if (transcript != null && cleaned.isEmpty()) {
                wavFile.delete()
                fail(sessionId, GatewayException.emptyTranscript(), null, configuration, generation)
                return
            }
            if (cleaned.isNotEmpty()) {
                wavFile.delete()
                deliver(cleaned, sessionId, configuration, source)
                return
            }
            // The stream failed after audio was captured; the complete WAV on disk
            // is exactly what the batch endpoints need.
            stream.cancel()
        } else {
            stream?.cancel()
            recordBatchFallback()
        }

        deliverBatch(
            checkNotNull(client),
            sessionId,
            wavFile,
            configuration.effectiveLanguage.wireValue,
            configuration.style.wireValue,
            configuration,
            source,
            generation,
        )
        } finally {
            streamPump?.cancel()
            streamReference.getAndSet(null)?.cancel()
            if (configuration.localTranscriptionEnabled && selectedLocalModelID != null) {
                localModels.endUse(settings.current().modelIdleTimeout.delayMs)
            }
        }
    }

    private fun gatewayClient(url: String, token: String) = GatewayClient(
        url, token,
        uploadPreparer = { GatewayUploadAudio.prepare(it, File(context.cacheDir, "gateway-uploads")) },
    )

    /**
     * Recording follows the user across apps until they press Finish, warning a
     * minute before the cap and stopping at it rather than recording forever.
     */
    private suspend fun awaitFinish(signal: CompletableDeferred<Unit>) {
        val startedAt = _state.value.startedAtElapsedMillis
        if (awaitSignalUntil(
                signal,
                startedAt + DictationState.RECORDING_WARNING_MILLIS,
            )
        ) {
            return
        }
        _state.update { it.copy(approachingLimit = true) }
        awaitSignalUntil(signal, startedAt + DictationState.MAXIMUM_RECORDING_MILLIS)
    }

    private suspend fun awaitSignalUntil(
        signal: CompletableDeferred<Unit>,
        deadlineElapsedMillis: Long,
    ): Boolean {
        if (signal.isCompleted) return true
        val remaining = deadlineElapsedMillis - SystemClock.elapsedRealtime()
        if (remaining <= 0) return signal.isCompleted
        return withTimeoutOrNull(remaining) {
            signal.await()
            true
        } ?: false
    }

    private fun markGatewayTranscribing(sessionId: UUID, source: DictationSource, generation: Int) {
        while (this.generation.get() == generation) {
            val current = _state.value
            if (current.sessionId != sessionId || current.phase != DictationPhase.UPLOADING) return
            if (_state.compareAndSet(current, current.copy(phase = DictationPhase.TRANSCRIBING))) {
                diagnostics.recordTiming("upload_completed", source.name)
                diagnostics.recordTiming("transcription_started", source.name)
                return
            }
        }
    }

    private suspend fun deliverBatch(
        client: GatewayClient,
        sessionId: UUID,
        wavFile: File,
        language: String,
        style: String,
        configuration: VocaPhoneSettings,
        source: DictationSource,
        generation: Int,
    ) {
        try {
            _state.update { it.copy(phase = DictationPhase.UPLOADING) }
            client.createSession(sessionId, language, style)
            diagnostics.recordTiming("upload_started", source.name)
            val uploaded = client.uploadAudio(sessionId, wavFile, finishOnUpload = true,
                onUploadFinished = { markGatewayTranscribing(sessionId, source, generation) })
            val session = client.finishUploaded(sessionId, uploaded)
            // Marker-only output means the model heard nothing worth writing.
            val transcript = DictatedTranscript.finished(
                session.transcript,
                style = configuration.style,
                language = configuration.effectiveLanguage.wireValue,
                styledUpstream = true,
                repairSpeech = configuration.repairSpeech,
                numbersAsDigits = configuration.numbersAsDigits,
                spokenEmoji = configuration.spokenEmoji,
                snippets = configuration.snippets,
                vocabulary = CustomVocabulary.terms(configuration.whisperVocabulary),
                isDictionaryWord = ::isEnglishWord,
            )
            if (transcript.isEmpty()) {
                throw GatewayException(
                    session.errorCode ?: "empty_transcript",
                    "Nothing was transcribed. Try dictating again.",
                    recoverable = false,
                )
            }
            wavFile.delete()
            deliver(transcript, sessionId, configuration, source)
        } catch (error: GatewayException) {
            fail(sessionId, error, wavFile, configuration, generation)
        }
    }

    private suspend fun deliverLocal(
        sessionId: UUID,
        wavFile: File,
        language: String,
        configuration: VocaPhoneSettings,
        source: DictationSource,
        generation: Int,
        conditioningStartSample: Int = 0,
        preparedTranscript: LocalTranscription? = null,
        transcriptionTimingRecorded: Boolean = false,
    ) {
        // Loading a model is seconds of silence with nothing on screen to explain
        // it, and changing the accuracy setting makes it happen again. Mirroring
        // it into the status line is the difference between a wait and a hang.
        val preparingJob = scope.launch {
            localModels.state.collect { models ->
                _state.update { state ->
                    state.copy(
                        statusDetail = models.preparing?.let { "Loading $it… Please wait." }
                            ?: "Transcribing on this phone… Please wait.",
                    )
                }
            }
        }
        try {
            _state.update { it.copy(phase = DictationPhase.TRANSCRIBING, streaming = false) }
            if (!transcriptionTimingRecorded) {
                diagnostics.recordTiming("local_transcription_started", source.name)
            }
            val modelID = configuration.localModelId.takeIf { it.isNotEmpty() }
                ?: error("Choose and download an on-device model first.")
            // A complete-WAV decode remains the recovery path. The incremental
            // candidate is only passed here after it proved that every audible
            // window was decoded with a stable running gain.
            val local = preparedTranscript ?: localModels.transcribe(
                wavFile,
                modelID,
                language,
                configuration.transcriptionQuality,
                configuration.whisperVocabulary,
                conditioningStartSample,
                configuration.translationTarget,
            )
            val transcript = styleLocalTranscript(local, configuration)
            if (transcript.isEmpty()) {
                throw GatewayException.emptyTranscript()
            }
            wavFile.delete()
            deliver(transcript, sessionId, configuration, source)
        } catch (error: Throwable) {
            fail(
                sessionId,
                GatewayException(
                    code = if (error is com.vocahq.vocaphone.local.LocalModelIntegrityException) {
                        "local_model_integrity"
                    } else {
                        "local_transcription_failed"
                    },
                    userMessage = error.message ?: "On-device transcription failed. Download the model again and retry.",
                    recoverable = true,
                ),
                wavFile,
                configuration,
                generation,
            )
        } finally {
            preparingJob.cancel()
            _state.update { it.copy(statusDetail = null) }
        }
    }

    /**
     * The styles punctuate by script, so the language they are given has to be
     * the one the finished text is written in. With Automatic selected the
     * request only says "auto", and a model that detected Hindi would otherwise
     * have its Devanagari finished with a Latin full stop. When translating,
     * that language is the target rather than the one that was spoken.
     */
    private fun styleLocalTranscript(
        local: LocalTranscription,
        configuration: VocaPhoneSettings,
    ): String = DictatedTranscript.finished(
        local.text,
        style = configuration.style,
        language = ModelLanguageSupport.outputLanguage(
            requested = configuration.effectiveLanguage.wireValue,
            reported = local.language,
            translateTo = configuration.translationTarget,
        ),
        repairSpeech = configuration.repairSpeech,
        numbersAsDigits = configuration.numbersAsDigits,
        spokenEmoji = configuration.spokenEmoji,
        snippets = configuration.snippets,
        vocabulary = CustomVocabulary.terms(configuration.whisperVocabulary),
        isDictionaryWord = ::isEnglishWord,
    )

    /**
     * The keyboard's shipped word list, for vocabulary correction's one
     * question: is this an ordinary word? Read once, on first use.
     */
    private val englishWords: Set<String> by lazy {
        runCatching {
            context.assets.open("en.txt").bufferedReader().useLines { lines ->
                lines.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toHashSet()
            }
        }.getOrDefault(emptySet())
    }

    private fun isEnglishWord(word: String): Boolean = word in englishWords

    private suspend fun deliver(
        transcript: String,
        sessionId: UUID,
        configuration: VocaPhoneSettings,
        source: DictationSource,
    ) {
        diagnostics.recordTiming("transcript_ready", source.name)
        // Reported here rather than after insertion: the transcript exists and
        // is correct at this point, and whether the keyboard managed to commit
        // it is a separate question with its own failure path.
        telemetry.firstDictationEver()
        lastRecordingMillis?.let { millis ->
            telemetry.dictationSucceeded(
                source = configuration.telemetrySource,
                duration = TelemetryDurationBucket.of(millis / 1_000.0),
                model = configuration.telemetryModel,
                quality = configuration.transcriptionQuality,
            )
        }
        val recordedMillis = lastRecordingMillis
        scope.launch { usageStats.record(transcript, recordedMillis) }
        val target = when (source) {
            DictationSource.IME -> imeInserter
            DictationSource.FLOATING -> floatingInserter.takeIf { configuration.automaticInsertion }
            DictationSource.COMPANION_APP -> null
        }
        val shouldInsert = target != null

        if (!shouldInsert) {
            _state.value = _state.value.copy(
                phase = DictationPhase.READY_TO_INSERT,
                transcript = transcript,
                level = 0f,
            )
            history.recordSuccess(
                sessionId = sessionId.toString(),
                language = configuration.effectiveLanguage.wireValue,
                style = configuration.style.wireValue,
                transcript = transcript,
                targetPackage = target?.currentTargetPackage(),
                insertedIntoField = false,
            )
            diagnostics.recordAction("ready_to_insert", source.name)
            return
        }

        _state.update { it.copy(phase = DictationPhase.INSERTING, transcript = transcript) }
        diagnostics.recordTiming("insertion_started", source.name)
        // The inserter is reacquired here rather than at Start, so a dictation
        // that followed the user into another app lands in the field they are
        // actually looking at.
        val report = target.insert(transcript)
        lastInsertion = report.applied
        history.recordSuccess(
            sessionId = sessionId.toString(),
            language = configuration.effectiveLanguage.wireValue,
            style = configuration.style.wireValue,
            transcript = transcript,
            targetPackage = report.applied?.packageName ?: target.currentTargetPackage(),
            insertedIntoField = report.outcome == InsertionOutcome.INSERTED,
        )
        diagnostics.recordAction(
            if (report.outcome == InsertionOutcome.INSERTED) "inserted" else "insertion_failed",
            source.name,
        )
        if (report.outcome == InsertionOutcome.INSERTED) {
            diagnostics.recordTiming("insertion_completed", source.name)
        }
        _state.value = _state.value.copy(
            phase = if (report.outcome == InsertionOutcome.INSERTED) {
                DictationPhase.INSERTED
            } else {
                DictationPhase.READY_TO_INSERT
            },
            transcript = transcript,
            level = 0f,
        )
        if (report.outcome == InsertionOutcome.INSERTED) {
            // "Inserted" is a confirmation, not a state the user acts on: after a
            // moment the keyboard returns to its idle mic on its own.
            lingerThenIdle(sessionId, DictationPhase.INSERTED, INSERTED_LINGER_MILLIS)
        }
    }

    private suspend fun fail(
        sessionId: UUID,
        error: GatewayException,
        wavFile: File?,
        configuration: VocaPhoneSettings,
        generation: Int,
    ) = withContext(NonCancellable) {
        diagnostics.recordError(errorCategory(error), activeSource?.name)
        telemetry.dictationFailed(
            stage = telemetryStage(error),
            reason = telemetryReason(error),
            source = configuration.telemetrySource,
            model = configuration.telemetryModel,
            quality = configuration.transcriptionQuality,
        )
        history.recordFailure(
            sessionId = sessionId.toString(),
            language = configuration.effectiveLanguage.wireValue,
            style = configuration.style.wireValue,
            errorCode = error.code,
            errorMessage = error.userMessage,
            recoverable = error.recoverable,
            audioFile = wavFile,
            retentionHours = configuration.audioRetention.hours,
            targetPackage = floatingInserter?.currentTargetPackage(),
        )
        // The history write above is the durable half and always runs: the audio
        // is preserved and Retry has to find it. Reporting the failure on screen
        // is the half that can arrive too late — this block is `NonCancellable`,
        // so a cancel, or the dictation started right after it, can have taken
        // the state over while the write was in flight.
        if (this@DictationController.generation.get() != generation) return@withContext
        _state.value = _state.value.copy(
            phase = DictationPhase.FAILED,
            level = 0f,
            failure = DictationFailure(error.code, error.userMessage, error.recoverable),
        )
        // Same idea as the "Inserted" confirmation: the keyboard needs the
        // strip back for suggestions and the clipboard chip. History still
        // has Retry if they want another pass.
        lingerThenIdle(sessionId, DictationPhase.FAILED, FAILED_LINGER_MILLIS)
    }

    private fun lingerThenIdle(sessionId: UUID, from: DictationPhase, millis: Long) {
        scope.launch {
            delay(millis)
            _state.update { current -> afterLinger(current, sessionId, from) }
        }
    }

    private fun announceStopped(tone: DictationTone) {
        cues.haptic()
        cues.stopCue(tone)
    }

    /** Retires whatever owned the state, so nothing older can write to it. */
    private fun nextGeneration(): Int = generation.incrementAndGet()

    private fun reset() {
        nextGeneration()
        _state.value = DictationState()
    }

    private suspend fun followDownload(target: String) {
        val outcome = localModels.state
            .map { latest ->
                downloadOutcome(latest, target).also {
                    when (it) {
                        DownloadOutcome.WAITING -> _state.update { state ->
                            state.copy(
                                missingPermissions = setOf(MissingPermission.MODEL_DOWNLOADING),
                                modelDownloadProgress = latest.progress,
                            )
                        }
                        DownloadOutcome.PREPARING -> _state.update { state ->
                            state.copy(
                                missingPermissions = setOf(MissingPermission.MODEL_PREPARING),
                                modelDownloadProgress = null,
                            )
                        }
                        else -> Unit
                    }
                }
            }
            .first { it != DownloadOutcome.WAITING && it != DownloadOutcome.PREPARING }
        when (outcome) {
            DownloadOutcome.LANDED -> reset()
            DownloadOutcome.DIED -> _state.update {
                it.copy(
                    missingPermissions = setOf(MissingPermission.LOCAL_MODEL_UNAVAILABLE),
                    modelDownloadProgress = null,
                )
            }
            DownloadOutcome.WAITING, DownloadOutcome.PREPARING -> Unit
        }
    }

    /**
     * How far the dictation got, from the error that ended it.
     *
     * Deliberately derived from `error.code` — a closed set the gateway client
     * defines — and never from `error.userMessage`, which is free text and can
     * name a host, a path, or whatever a server chose to return.
     */
    private fun telemetryStage(error: GatewayException): TelemetryStage = when {
        error.code.startsWith("audio") || error.code.startsWith("microphone") -> {
            TelemetryStage.CAPTURE
        }
        error.code.startsWith("insert") -> TelemetryStage.INSERTION
        error.code.startsWith("upload") || error.code == "unreachable" -> TelemetryStage.UPLOAD
        else -> TelemetryStage.TRANSCRIPTION
    }

    private fun telemetryReason(error: GatewayException): TelemetryReason = when (error.code) {
        "microphone_silenced" -> TelemetryReason.AUDIO_SILENCED
        "microphone_focus_lost" -> TelemetryReason.AUDIO_FOCUS_LOST
        "microphone_capture_lost" -> TelemetryReason.AUDIO_CAPTURE_LOST
        "permission_repair" -> TelemetryReason.PERMISSION
        "unreachable" -> TelemetryReason.GATEWAY_UNREACHABLE
        "unauthorized", "forbidden" -> TelemetryReason.GATEWAY_REJECTED
        "engine_not_ready" -> TelemetryReason.ENGINE_NOT_READY
        "model_missing" -> TelemetryReason.MODEL_MISSING
        "empty_transcript" -> TelemetryReason.TRANSCRIPT_EMPTY
        else -> when {
            error.code.startsWith("audio") || error.code.startsWith("microphone") -> {
                TelemetryReason.AUDIO
            }
            error.code.startsWith("insert") -> TelemetryReason.INSERTION_REJECTED
            // Unknown rather than the raw code. A code this mapper has not seen
            // is exactly the case where passing it through would put an
            // unreviewed string on the wire.
            else -> TelemetryReason.UNKNOWN
        }
    }

    private fun errorCategory(error: GatewayException): String = when {
        error.code == "microphone_silenced" -> "audio_silenced"
        error.code.startsWith("audio") -> "audio"
        error.code.startsWith("microphone") -> "audio"
        error.code.startsWith("insert") -> "insertion"
        error.code == "permission_repair" -> "setup"
        else -> "gateway"
    }

    /**
     * Which microphone failure this was. The on-device log is the only record
     * that survives the call or the screen recording that caused it, so the
     * cause is kept rather than flattened into a single "audio" category.
     */
    private fun audioErrorCategory(error: Throwable): String =
        if (error !is MicrophoneInterruptedException) {
            "audio"
        } else {
            when (error.interruption) {
                MicrophoneInterruption.FOCUS_LOST -> "audio_focus_lost"
                MicrophoneInterruption.SILENCED -> "audio_silenced"
                MicrophoneInterruption.CAPTURE_LOST -> "audio_capture_lost"
            }
        }

    private companion object {
        /** Below this, there is nothing a model could usefully transcribe. */
        const val MINIMUM_RECORDING_MILLIS = 300L

        /** How long the "Inserted" confirmation stays before the keyboard goes idle. */
        const val INSERTED_LINGER_MILLIS = 2_000L

        /** Long enough to read the empty-transcript line, short enough to give the strip back. */
        const val FAILED_LINGER_MILLIS = 3_000L

        /**
         * How long cancel waits for a LISTENING pipeline to close its WAV and
         * reset before forcing it. Covers capture teardown plus a generous
         * margin for the joins in the unwind path.
         */
        const val CANCEL_UNWIND_MILLIS = 2_500L

        /**
         * How long a settle waits for a cancelled pipeline's own tail to
         * finish (a `NonCancellable` history write outlives cancellation)
         * before deciding whether its WAV is orphaned.
         */
        const val SETTLE_JOIN_MILLIS = 1_000L

        /** File writing should stay far ahead of this six-second safety buffer. */
        const val FILE_FRAME_BUFFER_CAPACITY = 64

        /** Covers the eight-second socket timeout without unbounded PCM growth. */
        const val STREAM_FRAME_BUFFER_CAPACITY = 96
    }
}

/**
 * Whether the local route can run now, and if not, what the person is
 * waiting for. This is the one place that checks the stored model before the
 * microphone opens: without it a selection the catalog no longer has — or the
 * replacement the retired-model migration moved it to, which is in the
 * catalog but not on this phone yet — records a full dictation and fails at
 * delivery. A download or adoption of the model under way is a wait, not a
 * missing model, so it is checked before "unavailable".
 *
 * [configuredPresent] is a stat pass rather than [LocalModelState.downloaded],
 * which may not be filled in yet right after launch.
 */
internal fun modelRepair(
    configuredId: String,
    configuredPresent: Boolean,
    models: LocalModelState,
): MissingPermission? {
    val target = models.pendingUse ?: configuredId.takeIf { it.isNotEmpty() }
    return when {
        configuredPresent -> null
        target != null && models.downloading == target -> MissingPermission.MODEL_DOWNLOADING
        // On disk but the id is not persisted: adoption is loading it. A
        // wait, never a pass — dictating now would read an empty id.
        target != null && target in models.downloaded && models.pendingUse == target ->
            MissingPermission.MODEL_PREPARING
        else -> MissingPermission.LOCAL_MODEL_UNAVAILABLE
    }
}

/**
 * What a linger timer leaves behind when it fires: idle only if the state is
 * still the very one it was started for. A later session, or a newer failure
 * of the same phase, keeps the screen.
 */
internal fun afterLinger(current: DictationState, sessionId: UUID, from: DictationPhase): DictationState =
    if (current.sessionId == sessionId && current.phase == from) DictationState() else current

internal enum class DownloadOutcome { WAITING, PREPARING, LANDED, DIED }

internal fun downloadOutcome(latest: LocalModelState, target: String): DownloadOutcome =
    when {
        target in latest.downloaded && latest.pendingUse != target -> DownloadOutcome.LANDED
        target in latest.downloaded -> DownloadOutcome.PREPARING
        latest.downloading == target -> DownloadOutcome.WAITING
        else -> DownloadOutcome.DIED
    }

/**
 * The settings a repair state is about: where speech goes, which model, and
 * whether a gateway is set up. A change to any of them makes a repair stale.
 */
internal data class RepairInputs(
    val localTranscription: Boolean,
    val localModelId: String,
    val gatewayConfigured: Boolean,
) {
    constructor(settings: VocaPhoneSettings) : this(
        localTranscription = settings.localTranscriptionEnabled,
        localModelId = settings.localModelId,
        gatewayConfigured = settings.isConfigured,
    )
}

/** Whether a showing repair was worked out from settings that have since changed. */
internal fun repairOutlived(phase: DictationPhase, before: RepairInputs?, now: RepairInputs): Boolean =
    phase == DictationPhase.PERMISSION_REPAIR && before != null && before != now
