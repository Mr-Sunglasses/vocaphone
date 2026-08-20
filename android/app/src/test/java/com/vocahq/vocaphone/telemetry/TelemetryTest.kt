package com.vocahq.vocaphone.telemetry

import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.local.LocalModelCatalog
import java.time.Instant
import java.util.Locale
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * These tests are the privacy claim.
 *
 * The promise made in `docs/privacy.md` and on the onboarding screen is not
 * "we are careful about what we send" — it is that the code cannot send
 * anything else. That is only true while these pass.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class TelemetryTest {

    // MARK: - Fakes

    private class FakePreferences(
        var enabled: Boolean = true,
    ) : TelemetryPreferences {
        val claimed = mutableSetOf<String>()

        override suspend fun isEnabled(): Boolean = enabled
        override suspend fun setEnabled(enabled: Boolean) {
            this.enabled = enabled
        }

        override suspend fun claimMilestone(key: String): Boolean = claimed.add(key)
    }

    private class RecordingSink(
        private val outcome: TelemetryDelivery = TelemetryDelivery.DELIVERED,
    ) : TelemetrySink {
        val batches = mutableListOf<List<TelemetryRecord>>()
        val records: List<TelemetryRecord> get() = batches.flatten()

        override suspend fun send(batch: List<TelemetryRecord>): TelemetryDelivery {
            batches.add(batch)
            return outcome
        }
    }

    private val fixedProps = TelemetrySystemProps(
        locale = "en",
        osName = "Android",
        osVersion = "15",
        isDebug = false,
        appVersion = "0.1.0-beta.15",
        sdkVersion = TelemetryConfig.SDK_VERSION,
    )

    private fun telemetry(
        preferences: TelemetryPreferences,
        sink: TelemetrySink,
        scope: TestScope,
        queue: TelemetryQueue = TelemetryQueue(),
    ) = Telemetry(
        preferences = preferences,
        scope = scope,
        sink = sink,
        queue = queue,
        systemProps = { fixedProps },
        clock = { Instant.parse("2026-08-18T14:03:44Z") },
        // Off by default here so a batch count means what the test says it
        // means; `the queue flushes itself without an activity` covers it.
        autoFlushDelayMillis = null,
    )

    // MARK: - systemProps is an allowlist

    @Test
    fun `systemProps carries exactly the six approved keys`() {
        val json = fixedProps.toJson()

        assertEquals(TelemetrySystemProps.KEYS, json.keys().asSequence().toSet())
    }

    /**
     * The one that matters most. Aptabase's own SDKs send `deviceModel`, and
     * adopting one -- or hand-copying its system properties -- would quietly
     * reintroduce a fingerprint that the daily-rotating server-side hash exists
     * to prevent. If this test ever fails, the anonymity claim in the
     * onboarding copy has stopped being true.
     */
    @Test
    fun `no device identifier is ever sent`() {
        val serialized = fixedProps.toJson().toString().lowercase(Locale.ROOT)

        listOf("devicemodel", "device", "model", "manufacturer", "serial", "androidid")
            .forEach { forbidden ->
                assertFalse("systemProps must not carry $forbidden", serialized.contains(forbidden))
            }
    }

    @Test
    fun `osVersion is the major only, digits and nothing else`() {
        assertEquals("15", TelemetrySystemProps.majorVersion("15"))
        assertEquals("15", TelemetrySystemProps.majorVersion("15.1.1"))
        assertEquals("16", TelemetrySystemProps.majorVersion("16.0"))
        // Preview builds report things like "VanillaIceCream"; a letters-only
        // release must not smuggle a codename into the column.
        assertEquals("0", TelemetrySystemProps.majorVersion("VanillaIceCream"))
        assertEquals("0", TelemetrySystemProps.majorVersion(null))
        assertEquals("0", TelemetrySystemProps.majorVersion(""))
    }

    @Test
    fun `locale is the language subtag only, never the region`() {
        assertEquals("en", TelemetrySystemProps.languageSubtag(Locale.forLanguageTag("en-IN")))
        assertEquals("en", TelemetrySystemProps.languageSubtag(Locale.US))
        assertEquals("de", TelemetrySystemProps.languageSubtag(Locale.GERMANY))
        assertEquals("und", TelemetrySystemProps.languageSubtag(Locale.ROOT))
    }

    // MARK: - Off means off

    /**
     * Asserts on the sink rather than the queue on purpose. The interesting bug
     * is not "a disabled app sends events" -- it is a queue that fills up while
     * the switch is off and then floods the server the moment someone turns it
     * on, backdating a month of behaviour they thought they had declined.
     */
    @Test
    fun `nothing is queued or sent while reporting is off`() = runTest {
        val preferences = FakePreferences(enabled = false)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        telemetry.appFirstOpen()
        telemetry.setupStepCompleted(TelemetrySetupStep.MICROPHONE)
        telemetry.sourceSelected(TelemetrySource.ON_DEVICE)
        telemetry.dictationSucceeded(
            TelemetrySource.ON_DEVICE,
            TelemetryDurationBucket.UNDER_10S,
            model = null,
            quality = null,
        )
        telemetry.firstDictationEver()

        assertEquals(0, telemetry.pendingCount())

        preferences.enabled = true
        telemetry.flush()

        assertTrue("a backlog must not appear on enable", sink.records.isEmpty())
    }

    @Test
    fun `turning reporting off sends one final event and discards the queue`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        telemetry.sourceSelected(TelemetrySource.GATEWAY)
        telemetry.applyEnabled(false)

        assertFalse(preferences.enabled)
        assertEquals(0, telemetry.pendingCount())
        assertEquals(
            listOf("source_selected", "telemetry_disabled"),
            sink.records.map { it.eventName },
        )
    }

    // MARK: - One-shot milestones

    /**
     * The funnel is a ratio of once-ever counters, because Aptabase's daily
     * salt rotation makes per-user funnels impossible. That arithmetic is
     * silently wrong -- not obviously broken -- the moment a milestone fires
     * twice.
     */
    @Test
    fun `milestones fire once per install, however often they are called`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        repeat(3) {
            telemetry.appFirstOpen()
            telemetry.setupFinished()
            telemetry.firstDictationEver()
        }
        telemetry.flush()

        assertEquals(1, sink.records.count { it.eventName == "app_first_open" })
        assertEquals(1, sink.records.count { it.eventName == "setup_finished" })
        assertEquals(1, sink.records.count { it.eventName == "first_dictation_ever" })
    }

    @Test
    fun `each setup step is its own milestone`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        TelemetrySetupStep.entries.forEach { telemetry.setupStepCompleted(it) }
        TelemetrySetupStep.entries.forEach { telemetry.setupStepCompleted(it) }
        telemetry.flush()

        val steps = sink.records
            .filter { it.eventName == "setup_step_completed" }
            .map { it.props.getValue("step") }
        assertEquals(TelemetrySetupStep.entries.map { it.wire }, steps)
    }

    /**
     * The regression test for the defect that would have made this feature's
     * headline number permanently zero.
     *
     * Reporting is off by default and the opt-in is asked at the end of setup,
     * so `app_first_open` and every `setup_step_completed` happen *before* the
     * user can possibly say yes. Claiming milestones regardless of the switch
     * burnt them all while nothing could be sent, leaving
     * `first_dictation_ever / app_first_open` dividing by zero for every user
     * who ever opted in.
     */
    @Test
    fun `a milestone skipped while off still fires once reporting is on`() = runTest {
        val preferences = FakePreferences(enabled = false)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        // The real sequence: launch and finish setup with reporting off...
        telemetry.appFirstOpen()
        TelemetrySetupStep.entries.forEach { telemetry.setupStepCompleted(it) }

        telemetry.applyEnabled(true)

        // ...then the next launch, and setup status being re-read.
        telemetry.appFirstOpen()
        TelemetrySetupStep.entries.forEach { telemetry.setupStepCompleted(it) }
        telemetry.flush()

        assertEquals(
            "the funnel denominator must survive an opt-in that comes after setup",
            1,
            sink.records.count { it.eventName == "app_first_open" },
        )
        assertEquals(
            TelemetrySetupStep.entries.size,
            sink.records.count { it.eventName == "setup_step_completed" },
        )
    }

    /** Still once ever, though — being enabled does not re-arm a spent milestone. */
    @Test
    fun `a milestone already sent is not sent again`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        telemetry.appFirstOpen()
        telemetry.applyEnabled(false)
        telemetry.applyEnabled(true)
        telemetry.appFirstOpen()
        telemetry.flush()

        assertEquals(1, sink.records.count { it.eventName == "app_first_open" })
    }

    // MARK: - Queue behaviour

    @Test
    fun `the queue is bounded and drops the oldest`() {
        val queue = TelemetryQueue(capacity = 200)
        repeat(500) { index ->
            queue.add(
                TelemetryRecord(
                    eventName = "dictation_failed",
                    timestamp = Instant.EPOCH,
                    sessionId = "s",
                    systemProps = fixedProps,
                    props = mapOf("stage" to index.toString()),
                )
            )
        }

        val kept = queue.peekAll()
        assertEquals(200, kept.size)
        // The newest 200, not the oldest: a queue that dropped new events would
        // go deaf exactly when something started failing repeatedly.
        assertEquals("300", kept.first().props.getValue("stage"))
        assertEquals("499", kept.last().props.getValue("stage"))
    }

    @Test
    fun `batches never exceed the ingest limit`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        repeat(60) { telemetry.sourceSelected(TelemetrySource.GATEWAY) }
        telemetry.flush()

        assertTrue(sink.batches.isNotEmpty())
        sink.batches.forEach { batch ->
            assertTrue(
                "Aptabase rejects batches over ${TelemetryConfig.MAX_BATCH}",
                batch.size <= TelemetryConfig.MAX_BATCH,
            )
        }
        assertEquals(60, sink.records.size)
    }

    @Test
    fun `an unavailable server keeps the batch for the next flush`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink(TelemetryDelivery.UNAVAILABLE)
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        telemetry.sourceSelected(TelemetrySource.GATEWAY)
        telemetry.flush()

        assertEquals(1, sink.batches.size)
        assertEquals("the event is kept, not lost", 1, telemetry.pendingCount())
    }

    /** A 4xx will never succeed, so retrying it only costs battery. */
    @Test
    fun `a rejected batch is dropped rather than retried`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink(TelemetryDelivery.REJECTED)
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        telemetry.sourceSelected(TelemetrySource.GATEWAY)
        telemetry.flush()

        assertEquals(0, telemetry.pendingCount())
    }

    // MARK: - The wire format

    @Test
    fun `a record serializes to the shape Aptabase accepts`() {
        val record = TelemetryRecord(
            eventName = "dictation_failed",
            timestamp = Instant.parse("2026-08-18T14:03:44.465Z"),
            sessionId = "175552582412345678",
            systemProps = fixedProps,
            props = mapOf("stage" to "transcription", "reason" to "engine_not_ready"),
        )

        val json = record.toJson()

        assertEquals(
            setOf("timestamp", "sessionId", "eventName", "systemProps", "props"),
            json.keys().asSequence().toSet(),
        )
        assertEquals("2026-08-18T14:03:44.465Z", json.getString("timestamp"))
        assertEquals("dictation_failed", json.getString("eventName"))
        assertEquals("transcription", json.getJSONObject("props").getString("stage"))
    }

    /** Always UTC: a local offset would carry the user's timezone, a coarse location. */
    @Test
    fun `timestamps are UTC whatever the device timezone`() {
        val record = TelemetryRecord(
            eventName = "app_first_open",
            timestamp = Instant.parse("2026-01-01T23:30:00Z"),
            sessionId = "s",
            systemProps = fixedProps,
            props = emptyMap(),
        )

        assertTrue(record.toJson().getString("timestamp").endsWith("Z"))
        assertEquals("2026-01-01T23:30:00.000Z", record.toJson().getString("timestamp"))
    }

    @Test
    fun `the request body is a JSON array of events`() {
        val record = TelemetryRecord(
            eventName = "app_first_open",
            timestamp = Instant.EPOCH,
            sessionId = "s",
            systemProps = fixedProps,
            props = emptyMap(),
        )

        val parsed = JSONArray(listOf(record, record).toRequestBody())

        assertEquals(2, parsed.length())
        assertEquals("app_first_open", parsed.getJSONObject(0).getString("eventName"))
    }

    // MARK: - No content reaches the wire

    /**
     * The end-to-end version of the type-level guarantee: push a canary through
     * every event the app can emit and assert it appears nowhere in the
     * serialized payload. If someone adds a `String` parameter and a call site
     * passes a transcript, the compile-time defence and this test both fail.
     */
    @Test
    fun `no transcript or gateway detail can reach a payload`() = runTest {
        val canary = "SPOKEN-SECRET-9f2a"
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        telemetry.appFirstOpen()
        TelemetrySetupStep.entries.forEach { telemetry.setupStepCompleted(it) }
        telemetry.setupFinished()
        telemetry.sourceSelected(TelemetrySource.GATEWAY)
        telemetry.firstDictationEver()
        telemetry.dictationSucceeded(
            TelemetrySource.GATEWAY,
            TelemetryDurationBucket.OVER_60S,
            model = null,
            quality = null,
        )
        TelemetryReason.entries.forEach { reason ->
            telemetry.dictationFailed(
                TelemetryStage.UPLOAD,
                reason,
                TelemetrySource.GATEWAY,
                model = null,
                quality = null,
            )
        }

        val payload = telemetry.pendingPayload()
        telemetry.flush()

        assertFalse(payload.contains(canary))
        assertFalse(sink.records.toRequestBody().contains(canary))
        listOf("http://", "https://", "192.168.", ".local", "Bearer ", "/storage/")
            .forEach { forbidden ->
                assertFalse(
                    "a payload must never contain $forbidden",
                    sink.records.toRequestBody().contains(forbidden),
                )
            }
    }

    @Test
    fun `the payload viewer shows the literal wire JSON`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        telemetry.sourceSelected(TelemetrySource.ON_DEVICE)

        val shown = JSONArray(telemetry.pendingPayload())
        assertEquals(1, shown.length())
        val event: JSONObject = shown.getJSONObject(0)
        assertEquals("source_selected", event.getString("eventName"))
        // The viewer must not hide systemProps: it is the half of the payload
        // users are most likely to be suspicious about.
        assertEquals(
            TelemetrySystemProps.KEYS,
            event.getJSONObject("systemProps").keys().asSequence().toSet(),
        )
    }

    // MARK: - Delivery happens without an activity

    /**
     * The regression test for the bug that made this feature look broken on a
     * real phone.
     *
     * Flushing used to be driven only by `ProcessLifecycleOwner`, which observes
     * *activities*. A dictation from the VocaPhone keyboard inside another app
     * happens with no activity on screen at all, so no background transition was
     * ever reported, `onStop` never ran, and the event sat in the queue until
     * the process died. Every keyboard-only dictation -- which is to say almost
     * all of them -- was silently lost.
     *
     * Nothing here touches a lifecycle. Queueing an event has to be enough.
     */
    @Test
    fun `the queue flushes itself without an activity`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = Telemetry(
            preferences = preferences,
            scope = scope,
            sink = sink,
            systemProps = { fixedProps },
            clock = { Instant.parse("2026-08-18T14:03:44Z") },
            autoFlushDelayMillis = 5_000L,
        )

        telemetry.dictationSucceeded(
            TelemetrySource.ON_DEVICE,
            TelemetryDurationBucket.TEN_TO_30S,
            model = null,
            quality = null,
        )
        assertEquals("nothing leaves immediately", 0, sink.records.size)

        advanceTimeBy(6_000)

        assertEquals(1, sink.records.size)
        assertEquals("dictation_succeeded", sink.records.single().eventName)
        assertEquals(0, telemetry.pendingCount())
    }

    /** A burst is one request, not one per event. */
    @Test
    fun `events arriving together are coalesced into a single flush`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = Telemetry(
            preferences = preferences,
            scope = scope,
            sink = sink,
            systemProps = { fixedProps },
            clock = { Instant.parse("2026-08-18T14:03:44Z") },
            autoFlushDelayMillis = 5_000L,
        )

        telemetry.firstDictationEver()
        telemetry.dictationSucceeded(
            TelemetrySource.GATEWAY,
            TelemetryDurationBucket.UNDER_10S,
            model = null,
            quality = null,
        )
        telemetry.sourceSelected(TelemetrySource.GATEWAY)

        advanceTimeBy(6_000)

        assertEquals("one request, not three", 1, sink.batches.size)
        assertEquals(3, sink.records.size)
    }

    // MARK: - Delivery status

    /**
     * The counters exist to make "did this actually send?" answerable on the
     * phone. They must never become a second, quieter channel for content: no
     * event names, no property values, no payload fragments.
     */
    @Test
    fun `the delivery status reports counts and never content`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        telemetry.dictationSucceeded(
            TelemetrySource.GATEWAY,
            TelemetryDurationBucket.OVER_60S,
            model = null,
            quality = null,
        )
        telemetry.flush()

        val status = telemetry.deliveryStatus()

        assertTrue("it must say something was recorded", status.contains("1 recorded"))
        assertTrue("it must say something was sent", status.contains("1 sent"))
        listOf("dictation_succeeded", "gateway", "over_60s", "sessionId", "systemProps")
            .forEach { leaked ->
                assertFalse("the status line must not carry $leaked", status.contains(leaked))
            }
    }

    /**
     * The honest wording matters here. A 200 from Aptabase's ingest means the
     * JSON parsed, not that the events were stored -- an unknown app key gets
     * the same 200 as a good one -- so this line must not claim delivery.
     */
    /**
     * The status line is shown to every user on the "See what's sent" screen,
     * not just to whoever is debugging delivery, so it must not tell someone to
     * check a dashboard they do not have. It also must not claim more than the
     * device actually knows: Aptabase answers 200 to a batch it silently
     * discards -- an unknown app key gets the same 200 as a good one -- so
     * "sent" is honest and "stored" is not a claim this device can make.
     */
    @Test
    fun `a successful send says it was sent, without instructing the user to check a dashboard`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        telemetry.sourceSelected(TelemetrySource.ON_DEVICE)
        telemetry.flush()

        val status = telemetry.deliveryStatus()
        assertTrue(status.contains("sent"))
        assertFalse(
            "an ordinary user has no dashboard to check",
            status.contains("dashboard"),
        )
        assertFalse(
            "the device cannot confirm storage, only that the server accepted the batch",
            status.contains("stored"),
        )
    }

    @Test
    fun `an unreachable server says so rather than claiming success`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink(TelemetryDelivery.UNAVAILABLE)
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(preferences, sink, scope)

        telemetry.sourceSelected(TelemetrySource.ON_DEVICE)
        telemetry.flush()

        assertTrue(telemetry.deliveryStatus().contains("could not reach the server"))
    }

    @Test
    fun `a fresh session says nothing has been attempted`() {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher())
        val telemetry = telemetry(preferences, sink, scope)

        assertTrue(telemetry.deliveryStatus().contains("No send attempted yet"))
    }

    // MARK: - Which model ran, and how hard it worked

    @Test
    fun `an on-device dictation names the model and accuracy it ran with`() = runTest {
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(FakePreferences(enabled = true), sink, scope)
        val model = LocalModelCatalog.all.first()

        telemetry.dictationSucceeded(
            TelemetrySource.ON_DEVICE,
            TelemetryDurationBucket.UNDER_10S,
            model = model,
            quality = TranscriptionQuality.ACCURATE,
        )
        telemetry.flush()

        val props = sink.records.single().props
        assertEquals(model.id, props["model_id"])
        assertEquals("accurate", props["quality"])
    }

    /**
     * The gateway is the user's own machine and never tells the app what it
     * loaded. Reporting whichever local model happens to be selected would
     * attribute the session to a model that never saw the audio -- the exact
     * mistake that makes a "model X is slow" query wrong.
     */
    @Test
    fun `a gateway dictation reports the gateway rather than a local model`() = runTest {
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(FakePreferences(enabled = true), sink, scope)

        telemetry.dictationSucceeded(
            TelemetrySource.GATEWAY,
            TelemetryDurationBucket.UNDER_10S,
            model = LocalModelCatalog.all.first(),
            quality = TranscriptionQuality.FAST,
        )
        telemetry.dictationFailed(
            TelemetryStage.UPLOAD,
            TelemetryReason.GATEWAY_UNREACHABLE,
            TelemetrySource.GATEWAY,
            model = LocalModelCatalog.all.first(),
            quality = TranscriptionQuality.FAST,
        )
        telemetry.flush()

        sink.records.forEach { record ->
            assertEquals(TelemetryModelId.GATEWAY, record.props["model_id"])
            // The accuracy setting governs the local engines only, so claiming
            // the gateway ran at "fast" would be a plain untruth.
            assertEquals("not_applicable", record.props["quality"])
        }
    }

    /**
     * The one property whose value starts life as a string. A sideloaded
     * directory name or an identifier withdrawn from a later release must land
     * in the `unknown` bucket rather than on the wire.
     */
    @Test
    fun `a model outside the shipped catalog is reported as unknown`() = runTest {
        val sink = RecordingSink()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val telemetry = telemetry(FakePreferences(enabled = true), sink, scope)

        telemetry.dictationSucceeded(
            TelemetrySource.ON_DEVICE,
            TelemetryDurationBucket.UNDER_10S,
            model = LocalModelCatalog.all.first().copy(id = "/data/user/0/whisper-secret"),
            quality = TranscriptionQuality.BALANCED,
        )
        telemetry.flush()

        assertEquals(TelemetryModelId.UNKNOWN, sink.records.single().props["model_id"])
    }

    /**
     * A dictation this process never claimed -- one resumed after a restart --
     * knows neither value. Guessing at them would be worse than saying so.
     */
    @Test
    fun `an unknown local configuration is reported rather than guessed`() {
        assertEquals(TelemetryModelId.UNKNOWN, TelemetryModelId.of(null, TelemetrySource.ON_DEVICE))
        assertEquals(
            TelemetryQuality.NOT_APPLICABLE,
            TelemetryQuality.of(null, TelemetrySource.ON_DEVICE),
        )
    }

    // MARK: - Duration is bucketed, never exact

    @Test
    fun `recording length is bucketed rather than reported exactly`() {
        assertEquals(TelemetryDurationBucket.UNDER_10S, TelemetryDurationBucket.of(0.0))
        assertEquals(TelemetryDurationBucket.UNDER_10S, TelemetryDurationBucket.of(9.9))
        assertEquals(TelemetryDurationBucket.TEN_TO_30S, TelemetryDurationBucket.of(10.0))
        assertEquals(TelemetryDurationBucket.THIRTY_TO_60S, TelemetryDurationBucket.of(59.9))
        assertEquals(TelemetryDurationBucket.OVER_60S, TelemetryDurationBucket.of(60.0))
        // The 120s cap in AppConfiguration is the reason this bucket exists.
        assertEquals(TelemetryDurationBucket.OVER_60S, TelemetryDurationBucket.of(120.0))
    }

    @Test
    fun `setup with no events shows a labeled sample`() {
        val preferences = FakePreferences(enabled = true)
        val telemetry = telemetry(preferences, RecordingSink(), TestScope(UnconfinedTestDispatcher()))
        val inspect = telemetry.inspectPayload()

        assertTrue(inspect.isSample)
        val batch = JSONArray(inspect.json)
        val event = batch.getJSONObject(0)
        assertEquals("setup_step_completed", event.getString("eventName"))
        assertEquals(
            TelemetrySystemProps.KEYS,
            event.getJSONObject("systemProps").keys().asSequence().toSet(),
        )
        assertFalse(inspect.json.contains("deviceModel"))
        assertFalse(inspect.json.contains("transcript"))
        listOf("http://", "https://", "Bearer ").forEach { forbidden ->
            assertFalse(inspect.json.contains(forbidden))
        }
    }

    @Test
    fun `after a real event the viewer shows that event, not the sample`() = runTest {
        val preferences = FakePreferences(enabled = true)
        val sink = RecordingSink()
        val telemetry = telemetry(preferences, sink, TestScope(UnconfinedTestDispatcher(testScheduler)))

        telemetry.sourceSelected(TelemetrySource.ON_DEVICE)
        val beforeFlush = telemetry.inspectPayload()
        telemetry.flush()
        val afterFlush = telemetry.inspectPayload()

        assertFalse(beforeFlush.isSample)
        assertFalse(afterFlush.isSample)
        assertEquals(beforeFlush.json, afterFlush.json)
        assertEquals("source_selected", JSONArray(afterFlush.json).getJSONObject(0).getString("eventName"))
        assertEquals(0, telemetry.pendingCount())
    }
}
