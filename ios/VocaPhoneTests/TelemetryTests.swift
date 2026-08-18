import Foundation
import Testing

/// These tests are the privacy claim.
///
/// The promise made in `docs/privacy.md` and on the onboarding screen is not
/// "we are careful about what we send" — it is that the code cannot send
/// anything else. That is only true while these pass.
@MainActor
struct TelemetryTests {

    // MARK: - Fakes

    private final class FakePreferences: TelemetryPreferences {
        var enabled: Bool
        var claimed: Set<String> = []

        init(enabled: Bool) { self.enabled = enabled }

        var isEnabled: Bool { enabled }
        func setEnabled(_ enabled: Bool) { self.enabled = enabled }
        func claimMilestone(_ key: String) -> Bool { claimed.insert(key).inserted }
    }

    private final class RecordingSink: TelemetrySink, @unchecked Sendable {
        let outcome: TelemetryDelivery
        private(set) var batches: [[TelemetryRecord]] = []
        var records: [TelemetryRecord] { batches.flatMap { $0 } }

        init(outcome: TelemetryDelivery = .delivered) { self.outcome = outcome }

        func send(_ batch: [TelemetryRecord]) async -> TelemetryDelivery {
            batches.append(batch)
            return outcome
        }
    }

    private let fixedProps = TelemetrySystemProps(
        locale: "en",
        osName: "iOS",
        osVersion: "18",
        isDebug: false,
        appVersion: "0.1.0-beta.15",
        sdkVersion: TelemetryConfig.sdkVersion
    )

    private func makeTelemetry(
        preferences: TelemetryPreferences,
        sink: TelemetrySink,
        queue: TelemetryQueue = TelemetryQueue()
    ) -> Telemetry {
        Telemetry(
            preferences: preferences,
            sink: sink,
            queue: queue,
            systemProps: { [fixedProps] in fixedProps },
            clock: { Date(timeIntervalSince1970: 1_755_525_824) },
            // Off here so a batch count means what the test says it means.
            autoFlushDelay: nil
        )
    }

    private func encoded(_ records: [TelemetryRecord]) throws -> String {
        String(decoding: try records.requestBody(), as: UTF8.self)
    }

    // MARK: - systemProps is an allowlist

    @Test func systemPropsCarriesExactlyTheSixApprovedKeys() throws {
        let data = try JSONEncoder().encode(fixedProps)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(Set(object.keys) == TelemetrySystemProps.keys)
    }

    /// The one that matters most. Aptabase's own SDK sends `deviceModel`, and
    /// adopting it — or hand-copying its system properties — would quietly
    /// reintroduce a fingerprint that the daily-rotating server-side hash exists
    /// to prevent. If this fails, the anonymity claim in the onboarding copy has
    /// stopped being true.
    @Test func noDeviceIdentifierIsEverSent() throws {
        let serialized = try encoded([record(named: "app_first_open")]).lowercased()

        for forbidden in ["devicemodel", "manufacturer", "identifierforvendor", "serial"] {
            #expect(!serialized.contains(forbidden), "payload must not carry \(forbidden)")
        }
    }

    @Test func osVersionIsTheMajorOnly() {
        #expect(TelemetrySystemProps.majorVersion("18") == "18")
        #expect(TelemetrySystemProps.majorVersion("18.1.1") == "18")
        #expect(TelemetrySystemProps.majorVersion("26.0") == "26")
        #expect(TelemetrySystemProps.majorVersion(nil) == "0")
        #expect(TelemetrySystemProps.majorVersion("") == "0")
    }

    @Test func localeIsTheLanguageSubtagOnly() {
        #expect(TelemetrySystemProps.languageSubtag(Locale(identifier: "en_IN")) == "en")
        #expect(TelemetrySystemProps.languageSubtag(Locale(identifier: "de_DE")) == "de")
        #expect(TelemetrySystemProps.languageSubtag(Locale(identifier: "")) == "und")
    }

    // MARK: - Off means off

    /// Asserts on the sink rather than the queue on purpose. The interesting bug
    /// is not "a disabled app sends events" — it is a queue that fills up while
    /// the switch is off and then floods the server the moment someone turns it
    /// on, backdating a month of behaviour they thought they had declined.
    @Test func nothingIsQueuedOrSentWhileReportingIsOff() async {
        let preferences = FakePreferences(enabled: false)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        telemetry.appFirstOpen()
        telemetry.setupStepCompleted(.microphone)
        telemetry.sourceSelected(.onDevice)
        telemetry.dictationSucceeded(
            source: .onDevice, duration: .under10s, model: nil, quality: nil
        )
        telemetry.firstDictationEver()

        #expect(telemetry.pendingCount == 0)

        preferences.enabled = true
        await telemetry.flush()

        #expect(sink.records.isEmpty, "a backlog must not appear on enable")
    }

    @Test func turningReportingOffSendsOneFinalEventAndDiscardsTheQueue() async {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        telemetry.sourceSelected(.gateway)
        await telemetry.setEnabled(false)

        #expect(!preferences.enabled)
        #expect(telemetry.pendingCount == 0)
        #expect(sink.records.map(\.eventName) == ["source_selected", "telemetry_disabled"])
    }

    // MARK: - One-shot milestones

    /// The funnel is a ratio of once-ever counters, because Aptabase's daily
    /// salt rotation makes per-user funnels impossible. That arithmetic is
    /// silently wrong — not obviously broken — the moment a milestone fires
    /// twice.
    @Test func milestonesFireOncePerInstall() async {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        for _ in 0..<3 {
            telemetry.appFirstOpen()
            telemetry.setupFinished()
            telemetry.firstDictationEver()
        }
        await telemetry.flush()

        for event in ["app_first_open", "setup_finished", "first_dictation_ever"] {
            #expect(sink.records.filter { $0.eventName == event }.count == 1, "\(event) fired more than once")
        }
    }

    @Test func eachSetupStepIsItsOwnMilestone() async {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        for step in TelemetrySetupStep.allCases { telemetry.setupStepCompleted(step) }
        for step in TelemetrySetupStep.allCases { telemetry.setupStepCompleted(step) }
        await telemetry.flush()

        let steps = sink.records
            .filter { $0.eventName == "setup_step_completed" }
            .compactMap { $0.props["step"] }
        #expect(Set(steps) == Set(TelemetrySetupStep.allCases.map(\.rawValue)))
        #expect(steps.count == TelemetrySetupStep.allCases.count)
    }

    /// The regression test for the defect that would have made this feature's
    /// headline number permanently zero.
    ///
    /// Reporting is off by default and the opt-in is asked at the end of setup,
    /// so `app_first_open` and every `setup_step_completed` happen *before* the
    /// user can possibly say yes. Claiming milestones regardless of the switch
    /// burnt them all while nothing could be sent, leaving
    /// `first_dictation_ever / app_first_open` dividing by zero for every user
    /// who ever opted in.
    @Test func aMilestoneSkippedWhileOffStillFiresOnceReportingIsOn() async {
        let preferences = FakePreferences(enabled: false)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        // The real sequence: launch and finish setup with reporting off...
        telemetry.appFirstOpen()
        for step in TelemetrySetupStep.allCases { telemetry.setupStepCompleted(step) }

        await telemetry.setEnabled(true)

        // ...then the next launch, and setup status being re-read.
        telemetry.appFirstOpen()
        for step in TelemetrySetupStep.allCases { telemetry.setupStepCompleted(step) }
        await telemetry.flush()

        #expect(
            sink.records.filter { $0.eventName == "app_first_open" }.count == 1,
            "the funnel denominator must survive an opt-in that comes after setup"
        )
        #expect(
            sink.records.filter { $0.eventName == "setup_step_completed" }.count
                == TelemetrySetupStep.allCases.count
        )
    }

    /// Still once ever, though — being enabled does not re-arm a spent milestone.
    @Test func aMilestoneAlreadySentIsNotSentAgain() async {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        telemetry.appFirstOpen()
        await telemetry.setEnabled(false)
        await telemetry.setEnabled(true)
        telemetry.appFirstOpen()
        await telemetry.flush()

        #expect(sink.records.filter { $0.eventName == "app_first_open" }.count == 1)
    }

    // MARK: - Queue behaviour

    @Test func theQueueIsBoundedAndDropsTheOldest() {
        var queue = TelemetryQueue(capacity: 200)
        for index in 0..<500 {
            queue.add(record(named: "dictation_failed", props: ["stage": String(index)]))
        }

        #expect(queue.count == 200)
        // The newest 200, not the oldest: a queue that dropped new events would
        // go deaf exactly when something started failing repeatedly.
        #expect(queue.all.first?.props["stage"] == "300")
        #expect(queue.all.last?.props["stage"] == "499")
    }

    @Test func batchesNeverExceedTheIngestLimit() async {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        for _ in 0..<60 { telemetry.sourceSelected(.gateway) }
        await telemetry.flush()

        #expect(!sink.batches.isEmpty)
        for batch in sink.batches {
            #expect(batch.count <= TelemetryConfig.maxBatch)
        }
        #expect(sink.records.count == 60)
    }

    @Test func anUnavailableServerKeepsTheBatchForTheNextFlush() async {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink(outcome: .unavailable)
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        telemetry.sourceSelected(.gateway)
        await telemetry.flush()

        #expect(sink.batches.count == 1)
        #expect(telemetry.pendingCount == 1, "the event is kept, not lost")
    }

    /// A 4xx will never succeed, so retrying it only costs battery.
    @Test func aRejectedBatchIsDroppedRatherThanRetried() async {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink(outcome: .rejected)
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        telemetry.sourceSelected(.gateway)
        await telemetry.flush()

        #expect(telemetry.pendingCount == 0)
    }

    // MARK: - The wire format

    @Test func aRecordSerializesToTheShapeAptabaseAccepts() throws {
        let json = try encoded([record(named: "dictation_failed", props: ["stage": "upload"])])
        let array = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        let event = try #require(array.first)

        #expect(Set(event.keys) == ["timestamp", "sessionId", "eventName", "systemProps", "props"])
        #expect(event["eventName"] as? String == "dictation_failed")
    }

    /// Always UTC: a local offset would carry the user's timezone, a coarse
    /// location.
    @Test func timestampsAreUTCWhateverTheDeviceTimezone() throws {
        let json = try encoded([record(named: "app_first_open")])
        let array = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        let timestamp = try #require(array.first?["timestamp"] as? String)

        #expect(timestamp.hasSuffix("Z"), "\(timestamp) is not UTC")
    }

    // MARK: - No content reaches the wire

    /// The end-to-end version of the type-level guarantee: push every event the
    /// app can emit through the pipeline and assert nothing resembling user
    /// content or infrastructure detail appears in the serialized payload.
    @Test func noTranscriptOrGatewayDetailCanReachAPayload() async throws {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        telemetry.appFirstOpen()
        for step in TelemetrySetupStep.allCases { telemetry.setupStepCompleted(step) }
        telemetry.setupFinished()
        telemetry.sourceSelected(.gateway)
        telemetry.firstDictationEver()
        // Deliberately a path rather than a catalog entry: `model_id` is the one
        // property whose value starts life as a string, so the leak check is
        // only worth anything if it is handed something that would leak.
        telemetry.dictationSucceeded(
            source: .onDevice,
            duration: .over60s,
            model: Self.sideloadedModel,
            quality: .accurate
        )
        for reason in TelemetryReason.allCases {
            telemetry.dictationFailed(
                stage: .upload,
                reason: reason,
                source: .onDevice,
                model: Self.sideloadedModel,
                quality: .accurate
            )
        }
        telemetry.modelDownloadFinished(model: Self.sideloadedModel, outcome: .integrityFailed)

        let shown = telemetry.pendingPayload()
        await telemetry.flush()
        let sent = try encoded(sink.records)

        for forbidden in ["http://", "https://", "192.168.", ".local", "Bearer ", "/var/mobile"] {
            #expect(!sent.contains(forbidden), "a payload must never contain \(forbidden)")
            #expect(!shown.contains(forbidden))
        }
    }

    @Test func thePayloadViewerShowsTheLiteralWireJSON() throws {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        telemetry.sourceSelected(.onDevice)

        let array = try #require(
            JSONSerialization.jsonObject(with: Data(telemetry.pendingPayload().utf8))
                as? [[String: Any]]
        )
        #expect(array.count == 1)
        #expect(array.first?["eventName"] as? String == "source_selected")
        // The viewer must not hide systemProps: it is the half of the payload
        // users are most likely to be suspicious about.
        let system = try #require(array.first?["systemProps"] as? [String: Any])
        #expect(Set(system.keys) == TelemetrySystemProps.keys)
    }

    // MARK: - Duration is bucketed, never exact

    @Test func recordingLengthIsBucketedRatherThanReportedExactly() {
        #expect(TelemetryDurationBucket.of(0) == .under10s)
        #expect(TelemetryDurationBucket.of(9.9) == .under10s)
        #expect(TelemetryDurationBucket.of(10) == .tenTo30s)
        #expect(TelemetryDurationBucket.of(59.9) == .thirtyTo60s)
        #expect(TelemetryDurationBucket.of(60) == .over60s)
        // The 120s cap in AppConfiguration is the reason this bucket exists.
        #expect(TelemetryDurationBucket.of(AppConfiguration.maximumRecordingSeconds) == .over60s)
    }

    // MARK: - Vocabulary hygiene

    @Test func everyWireNameIsLowerSnakeCaseAndUnique() {
        let names = TelemetryEvent.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count, "duplicate event names")

        let values =
            names + TelemetrySetupStep.allCases.map(\.rawValue)
            + TelemetrySource.allCases.map(\.rawValue)
            + TelemetryStage.allCases.map(\.rawValue)
            + TelemetryReason.allCases.map(\.rawValue)
            + TelemetryDurationBucket.allCases.map(\.rawValue)
            + TelemetryDownloadOutcome.allCases.map(\.rawValue)

        for value in values {
            #expect(
                value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
                    && value.first != "_",
                "\(value) will not group cleanly in a query"
            )
        }
    }

    /// The one-shot set is what the funnel arithmetic divides by, so an event
    /// added to it without a `recordOnce` call site — or the reverse — silently
    /// skews a ratio rather than breaking anything.
    @Test func oneShotEventsAreTheOnesTheFunnelCounts() {
        #expect(TelemetryEvent.oneShot == [.appFirstOpen, .setupStepCompleted, .setupFinished, .firstDictationEver])
    }

    // MARK: - Delivery happens without a scene-phase change

    /// The regression test for the bug that made this feature look broken on a
    /// real phone.
    ///
    /// Flushing used to be driven only by a `scenePhase` transition. A dictation
    /// can complete while the app is already in the background — Quick Dictation
    /// keeps it alive for up to ten minutes precisely so it can — and no
    /// transition ever fires, so the event sat in the queue until the process
    /// ended. Nothing here touches a scene phase: queueing an event has to be
    /// enough.
    @Test func theQueueFlushesItselfWithoutASceneChange() async throws {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = Telemetry(
            preferences: preferences,
            sink: sink,
            systemProps: { [fixedProps] in fixedProps },
            clock: { Date(timeIntervalSince1970: 1_755_525_824) },
            autoFlushDelay: .milliseconds(50)
        )

        telemetry.dictationSucceeded(
            source: .onDevice, duration: .tenTo30s, model: nil, quality: nil
        )
        #expect(sink.records.isEmpty, "nothing leaves immediately")

        try await Task.sleep(for: .milliseconds(400))

        #expect(sink.records.count == 1)
        #expect(sink.records.first?.eventName == "dictation_succeeded")
        #expect(telemetry.pendingCount == 0)
    }

    /// A burst is one request, not one per event.
    @Test func eventsArrivingTogetherAreCoalescedIntoASingleFlush() async throws {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = Telemetry(
            preferences: preferences,
            sink: sink,
            systemProps: { [fixedProps] in fixedProps },
            clock: { Date(timeIntervalSince1970: 1_755_525_824) },
            autoFlushDelay: .milliseconds(50)
        )

        telemetry.firstDictationEver()
        telemetry.dictationSucceeded(
            source: .gateway, duration: .under10s, model: nil, quality: nil
        )
        telemetry.sourceSelected(.gateway)

        try await Task.sleep(for: .milliseconds(400))

        #expect(sink.batches.count == 1, "one request, not three")
        #expect(sink.records.count == 3)
    }

    // MARK: - Delivery status

    /// The counters exist to make "did this actually send?" answerable on the
    /// phone. They must never become a second, quieter channel for content.
    @Test func theDeliveryStatusReportsCountsAndNeverContent() async {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        telemetry.dictationSucceeded(
            source: .gateway, duration: .over60s, model: nil, quality: nil
        )
        await telemetry.flush()

        let status = telemetry.deliveryStatus
        #expect(status.contains("1 recorded"))
        #expect(status.contains("1 sent"))
        for leaked in ["dictation_succeeded", "gateway", "over_60s", "sessionId", "systemProps"] {
            #expect(!status.contains(leaked), "the status line must not carry \(leaked)")
        }
    }

    /// A 200 from Aptabase means the JSON parsed, not that the events were
    /// stored — an unknown app key gets the same 200 — so this line must not
    /// claim delivery.
    /// The status line is shown to every user on the "See what's sent" screen,
    /// not just to whoever is debugging delivery, so it must not tell someone to
    /// check a dashboard they do not have. It also must not claim more than the
    /// device actually knows: Aptabase answers 200 to a batch it silently
    /// discards — an unknown app key gets the same 200 as a good one — so "sent"
    /// is honest and "stored" is not a claim this device can make.
    @Test func aSuccessfulSendSaysItWasSentWithoutInstructingTheUserToCheckADashboard() async {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        telemetry.sourceSelected(.onDevice)
        await telemetry.flush()

        #expect(telemetry.deliveryStatus.contains("sent"))
        #expect(
            !telemetry.deliveryStatus.contains("dashboard"),
            "an ordinary user has no dashboard to check"
        )
        #expect(
            !telemetry.deliveryStatus.contains("stored"),
            "the device cannot confirm storage, only that the server accepted the batch"
        )
    }

    @Test func anUnreachableServerSaysSoRatherThanClaimingSuccess() async {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink(outcome: .unavailable)
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        telemetry.sourceSelected(.onDevice)
        await telemetry.flush()

        #expect(telemetry.deliveryStatus.contains("could not reach the server"))
    }

    // MARK: - Failure mapping

    /// Derived from the closed set of failure codes this app defines, never from
    /// the failure message, which is free text and can name a host or a path.
    @Test func failureCodesMapToTheClosedVocabulary() {
        #expect(
            TelemetryFailureMapping.stage(for: "microphone_permission_denied") == .capture)
        #expect(TelemetryFailureMapping.reason(for: "microphone_permission_denied") == .permission)
        #expect(TelemetryFailureMapping.stage(for: "gateway_not_configured") == .upload)
        #expect(TelemetryFailureMapping.stage(for: "local_transcription_failed") == .transcription)
        #expect(TelemetryFailureMapping.reason(for: "microphone_silenced") == .audioSilenced)
        // An unmapped code must not be passed through as-is.
        #expect(TelemetryFailureMapping.reason(for: "something_new_and_unreviewed") == .unknown)
    }

    // MARK: - Configuration

    /// The Aptabase ingest key is committed rather than injected, which means a
    /// typo in it is a silent failure: the app keeps queueing events and every
    /// flush is rejected, with nothing visible to the user and nothing in a
    /// crash report. This is what turns that into a build failure.
    @Test func aSelfHostedKeyIsTheOnlyShapeAccepted() {
        #expect(TelemetryConfig.isSelfHostedKey("A-SH-3275173609"))

        // Blanked by a fork.
        #expect(!TelemetryConfig.isSelfHostedKey(""))
        // The prefix on its own is not a key.
        #expect(!TelemetryConfig.isSelfHostedKey("A-SH-"))
        // Aptabase Cloud keys. Accepting one would point a build that believes
        // it is self-hosted at eu./us.aptabase.com instead, which is the one
        // mistake here that would actually send data to a third party.
        #expect(!TelemetryConfig.isSelfHostedKey("A-EU-3275173609"))
        #expect(!TelemetryConfig.isSelfHostedKey("A-US-3275173609"))
    }

    @Test func thisBuildIsPointedAtOurOwnInstanceOverTLS() {
        #expect(TelemetryConfig.isSelfHostedKey(TelemetryConfig.appKey))
        // An ingest posted over cleartext would put the counters, and the key,
        // on the wire in the open.
        #expect(TelemetryConfig.host.hasPrefix("https://"))
        #expect(TelemetryConfig.ingestURL != nil)
    }

    /// Debug builds queue events so the "See what's sent" screen is useful
    /// while developing, and never transmit them. Without this the dataset
    /// fills with runs of a tree that corresponds to no release.
    @Test func aDebugBuildNeverTransmits() {
        #expect(!TelemetryConfig.canTransmit)
    }

    // MARK: - Which model ran, and how hard it worked

    /// A model that is not in the shipped catalog, shaped like the thing that
    /// would actually do damage if pinning ever stopped happening.
    static let sideloadedModel = LocalModelDescriptor(
        id: "/var/mobile/Containers/Data/whisper-secret",
        displayName: "Sideloaded",
        engine: .whisperKit,
        tokenizerRepository: "openai/whisper-tiny",
        sizeBytes: 1,
        minimumRamGB: 1,
        languages: "English",
        englishOnly: true
    )

    @Test func anOnDeviceDictationNamesTheModelAndAccuracyItRanWith() async throws {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)
        let model = try #require(LocalModelCatalog.all.first)

        telemetry.dictationSucceeded(
            source: .onDevice, duration: .under10s, model: model, quality: .accurate
        )
        await telemetry.flush()

        let props = try #require(sink.records.first?.props)
        #expect(props["model_id"] == model.id)
        #expect(props["quality"] == "accurate")
    }

    /// The gateway is the user's own machine and never tells the app what it
    /// loaded. Reporting whichever local model happens to be selected would
    /// attribute the session to a model that never saw the audio — the exact
    /// mistake that makes a "model X is slow" query wrong.
    @Test func aGatewayDictationReportsTheGatewayRatherThanALocalModel() async throws {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)
        let model = try #require(LocalModelCatalog.all.first)

        telemetry.dictationSucceeded(
            source: .gateway, duration: .under10s, model: model, quality: .fast
        )
        telemetry.dictationFailed(
            stage: .upload,
            reason: .gatewayUnreachable,
            source: .gateway,
            model: model,
            quality: .fast
        )
        await telemetry.flush()

        #expect(sink.records.count == 2)
        for record in sink.records {
            #expect(record.props["model_id"] == TelemetryModelID.gateway)
            // The accuracy setting governs the local engines only, so claiming
            // the gateway ran at "fast" would be a plain untruth.
            #expect(record.props["quality"] == "not_applicable")
        }
    }

    /// A sideloaded directory, or a catalog entry withdrawn in a later release,
    /// lands in the `unknown` bucket rather than on the wire.
    @Test func aModelOutsideTheShippedCatalogIsReportedAsUnknown() async throws {
        let preferences = FakePreferences(enabled: true)
        let sink = RecordingSink()
        let telemetry = makeTelemetry(preferences: preferences, sink: sink)

        telemetry.dictationSucceeded(
            source: .onDevice,
            duration: .under10s,
            model: Self.sideloadedModel,
            quality: .balanced
        )
        await telemetry.flush()

        #expect(sink.records.first?.props["model_id"] == TelemetryModelID.unknown)
    }

    /// A dictation this process never claimed — one resumed after a relaunch —
    /// knows neither value. Guessing at them would be worse than saying so.
    @Test func anUnknownLocalConfigurationIsReportedRatherThanGuessed() {
        #expect(TelemetryModelID.of(nil, source: .onDevice) == TelemetryModelID.unknown)
        #expect(TelemetryQuality.of(nil, source: .onDevice) == .notApplicable)
    }

    // MARK: - Helpers

    private func record(named name: String, props: [String: String] = [:]) -> TelemetryRecord {
        TelemetryRecord(
            timestamp: Date(timeIntervalSince1970: 1_755_525_824),
            sessionId: "175552582412345678",
            eventName: name,
            systemProps: fixedProps,
            props: props
        )
    }
}
