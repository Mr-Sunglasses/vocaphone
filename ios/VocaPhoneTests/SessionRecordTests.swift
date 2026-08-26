import Foundation
import Testing

struct SessionRecordTests {
    @Test func validTransitionIncrementsRevision() throws {
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        #expect(record.state == .launchingApp)
        #expect(record.revision == 1)
    }

    @Test func invalidTransitionIsRejected() {
        var record = SessionRecord()
        #expect(throws: SessionTransitionError.invalid(from: .idle, to: .readyToInsert)) {
            try record.transition(to: .readyToInsert)
        }
    }

    /// A microphone another app silenced produces a file that no retry can turn
    /// into a transcript, so finishing must be able to fail permanently without
    /// first pretending the recording is worth uploading.
    @Test func aCaptureKnownUnusableFailsWithoutBeingUploaded() throws {
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try record.transition(to: .recording)
        try record.transition(to: .finalizing)
        try record.transition(to: .transcriptionFailedPermanent)

        #expect(record.state.isTerminal)
        #expect(!record.canRetry)
    }

    @Test func sharedStoreRoundTripsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try store.save(record)
        #expect(try store.load(record.sessionID) == record)
    }

    @Test func meterUpdatesCannotOverwriteAKeyboardStateTransition() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try record.transition(to: .recording)
        try store.save(record)
        try store.saveMeter(0.8, for: record.sessionID)

        let recording = try #require(try store.load(record.sessionID))
        #expect(recording.state == .recording)
        #expect(recording.meterLevel == 0.8)

        try record.transition(to: .finalizing)
        try store.save(record)
        // Simulate one late microphone callback racing with the keyboard tap.
        try store.saveMeter(0.4, for: record.sessionID)

        let finalizing = try #require(try store.load(record.sessionID))
        #expect(finalizing.state == .finalizing)
        #expect(finalizing.meterLevel == 0)
    }

    @Test func aParkedTranscriptSurvivesUntilTheOriginalFieldReturns() throws {
        var record = SessionRecord()
        for state in [
            SessionState.launchingApp, .recording, .finalizing, .uploading,
            .transcribing, .readyToInsert,
        ] {
            try record.transition(to: state)
        }

        try record.transition(to: .targetContextChanged)
        #expect(!record.state.isTerminal)

        try record.transition(to: .readyToInsert)
        try record.transition(to: .inserting)
        #expect(record.state == .inserting)
    }

    @Test func aParkedTranscriptCanBeDiscarded() throws {
        var record = SessionRecord()
        for state in [
            SessionState.launchingApp, .recording, .finalizing, .uploading,
            .transcribing, .readyToInsert, .targetContextChanged,
        ] {
            try record.transition(to: state)
        }

        try record.transition(to: .canceled)
        #expect(record.state.isTerminal)
    }

    @Test func inContainingAppFlagRoundTripsAndDefaultsToUnknown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)

        var record = SessionRecord()
        #expect(record.startedInContainingApp == nil)
        record.startedInContainingApp = true
        try record.transition(to: .launchingApp)
        try store.save(record)

        #expect(try store.load(record.sessionID)?.startedInContainingApp == true)
    }

    @Test func quickDictationPreferenceRoundTripsAndDefaultsToUnknown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)

        var record = SessionRecord()
        #expect(record.prefersQuickDictation == nil)
        record.prefersQuickDictation = true
        try record.transition(to: .launchingApp)
        try store.save(record)

        #expect(try store.load(record.sessionID)?.prefersQuickDictation == true)
    }

    /// Records written before the field existed must still decode, otherwise a
    /// pending dictation would be dropped on upgrade.
    @Test func recordsWithoutTheContainingAppFlagStillDecode() throws {
        let json = """
        {"createdAt":"2026-01-01T00:00:00Z","language":"auto","meterLevel":0,\
        "revision":1,"schemaVersion":1,"sessionID":"11111111-1111-1111-1111-111111111111",\
        "state":"recording","style":"casual","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SessionRecord.self, from: Data(json.utf8))

        #expect(record.startedInContainingApp == nil)
        #expect(record.prefersQuickDictation == nil)
        #expect(record.state == .recording)
        // No processing location either. The interface answers that with
        // neutral wording rather than guessing a route.
        #expect(record.processingLocation == nil)
    }

    /// Both routes survive a write and a read through the shared container,
    /// which is the only channel the keyboard and the Live Activity have for
    /// learning where the work is happening.
    @Test func bothProcessingLocationsRoundTripThroughTheSharedStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)

        for location in [SessionProcessingLocation.onDevice, .gateway] {
            var record = SessionRecord()
            record.processingLocation = location
            try store.save(record)
            #expect(try store.load(record.sessionID)?.processingLocation == location)
        }
    }

    /// A route recorded at claim time has to survive every later transition:
    /// the keyboard reads it while the app is in the background and cannot ask
    /// again.
    @Test func theProcessingLocationSurvivesTransitions() throws {
        var record = SessionRecord()
        record.processingLocation = .gateway
        try record.transition(to: .launchingApp)
        try record.transition(to: .recording)
        try record.transition(to: .finalizing)
        try record.transition(to: .uploading)

        #expect(record.processingLocation == .gateway)
    }

    @Test func mostRecentReturnsTheNewestSessionWithoutScanningEverything() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        let identifiers = try Self.seedSessions(count: 3, in: directory, store: store)

        #expect(try store.mostRecent()?.sessionID == identifiers.last)
    }

    @Test func pruningKeepsOnlyTheNewestSessions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        let identifiers = try Self.seedSessions(count: 5, in: directory, store: store)

        #expect(try store.pruneSessions(keeping: 2) == 3)
        #expect(try store.recent(limit: 10).map(\.sessionID) == identifiers.suffix(2).reversed())
    }

    @Test func pruningDropsStaleTerminalSessionsInsideTheWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        var record = SessionRecord(now: Date(timeIntervalSince1970: 1_000))
        try record.transition(to: .launchingApp, now: Date(timeIntervalSince1970: 1_000))
        try record.transition(to: .canceled, now: Date(timeIntervalSince1970: 1_000))
        try store.save(record)

        let laterThanRetention = Date(timeIntervalSince1970: 1_000 + 8 * 24 * 60 * 60)
        #expect(try store.pruneSessions(keeping: 50, now: laterThanRetention) == 1)
        #expect(try store.mostRecent() == nil)
    }

    /// The bar offers Cancel in every live state, so every live state has to
    /// accept it. Transcription did not, and the tap reported "The session
    /// changed. Please try again." while the session carried on regardless.
    @Test func cancelIsAcceptedWhereverTheBarOffersIt() throws {
        for abandonAfter in [
            SessionState.launchingApp, .awaitingReturn, .recording, .finalizing,
            .uploading, .transcribing, .readyToInsert, .targetContextChanged,
        ] {
            var record = SessionRecord()
            for state in Self.route(to: abandonAfter) {
                try record.transition(to: state)
            }
            #expect(record.state == abandonAfter)
            try record.transition(to: .canceled)
            #expect(record.state.isTerminal)
        }
    }

    /// The shortest legal sequence of transitions that arrives at `state`.
    private static func route(to state: SessionState) -> [SessionState] {
        let pipeline: [SessionState] = [
            .launchingApp, .recording, .finalizing, .uploading, .transcribing,
            .readyToInsert, .targetContextChanged,
        ]
        if state == .awaitingReturn { return [.launchingApp, .awaitingReturn] }
        guard let end = pipeline.firstIndex(of: state) else { return [state] }
        return Array(pipeline.prefix(through: end))
    }

    // MARK: - Expiry

    /// The keyboard adopts the newest non-terminal session every time it
    /// appears, in any app. A hand-off nobody completed therefore has to become
    /// terminal on its own, or it is a permanent "Opening vocaphone" bar.
    @Test func anUncompletedHandoffExpiresRatherThanWaitingForever() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        for state in [SessionState.launchingApp, .awaitingReturn] {
            var record = SessionRecord(now: start)
            try record.transition(to: .launchingApp, now: start)
            if state == .awaitingReturn {
                try record.transition(to: .awaitingReturn, now: start)
            }

            let withinWindow = start.addingTimeInterval(
                SessionExpiryPolicy.handoffWindow - 1
            )
            #expect(!SessionExpiryPolicy.isStale(record, now: withinWindow))
            #expect(SessionExpiryPolicy.isStale(
                record,
                now: start.addingTimeInterval(SessionExpiryPolicy.handoffWindow + 1)
            ))
        }
    }

    /// The audio the user is speaking must never be retired underneath them, so
    /// the capture window has to clear the hard recording cap by a wide margin.
    @Test func aLiveRecordingOutlastsTheCapItIsAlreadyBoundedBy() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var record = SessionRecord(now: start)
        try record.transition(to: .launchingApp, now: start)
        try record.transition(to: .recording, now: start)

        #expect(!SessionExpiryPolicy.isStale(
            record,
            now: start.addingTimeInterval(AppConfiguration.maximumRecordingSeconds + 60)
        ))
        #expect(SessionExpiryPolicy.isStale(
            record,
            now: start.addingTimeInterval(SessionExpiryPolicy.captureWindow + 1)
        ))
    }

    /// A transcript in flight belongs to the field it was dictated for, and the
    /// hand-off back to that field is measured in seconds. Keeping it offered
    /// indefinitely is what let yesterday's dictation land in today's field.
    @Test func anAbandonedTranscriptStopsBeingOfferedEventually() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var record = SessionRecord(now: start)
        for state in [
            SessionState.launchingApp, .recording, .finalizing, .uploading,
            .transcribing, .readyToInsert,
        ] {
            try record.transition(to: state, now: start)
        }

        #expect(!SessionExpiryPolicy.isStale(record, now: start.addingTimeInterval(60)))
        #expect(SessionExpiryPolicy.isStale(
            record,
            now: start.addingTimeInterval(SessionExpiryPolicy.pendingUserActionWindow + 1)
        ))
    }

    /// Terminal states have already stopped; expiring them again would rewrite
    /// finished history and re-notify every observer.
    @Test func settledSessionsAreNeverExpiredAgain() {
        for state in SessionState.allCases where state.isTerminal {
            #expect(SessionExpiryPolicy.window(for: state) == nil)
        }
    }

    /// Expiry is durable so the other process learns about it from the shared
    /// record rather than each one running its own timer.
    @Test func expiringWritesThroughSoBothProcessesAgree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        let start = Date(timeIntervalSince1970: 1_000)
        var record = SessionRecord(now: start)
        try record.transition(to: .launchingApp, now: start)
        try store.save(record)

        let fresh = SessionExpiryPolicy.expireIfStale(
            record,
            in: store,
            now: start.addingTimeInterval(10)
        )
        #expect(fresh == nil)
        #expect(try store.load(record.sessionID)?.state == .launchingApp)

        let expired = SessionExpiryPolicy.expireIfStale(
            record,
            in: store,
            now: start.addingTimeInterval(SessionExpiryPolicy.handoffWindow + 1)
        )
        #expect(expired?.state == .expired)
        #expect(try store.load(record.sessionID)?.state == .expired)
    }

    /// The keyboard's launch fallback reads this to tell "the app never heard
    /// me" from "the app is warming the microphone", which is the difference
    /// between rescuing a dictation and yanking the user out of their app.
    @Test func aClaimedHandoffRoundTripsAndDefaultsToUnclaimed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)

        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try store.save(record)
        #expect(try store.load(record.sessionID)?.claimedAt == nil)

        record.claimedAt = Date(timeIntervalSince1970: 2_000)
        try store.save(record)
        #expect(
            try store.load(record.sessionID)?.claimedAt
                == Date(timeIntervalSince1970: 2_000)
        )
        // Claiming is not a state change: the hand-off is still outstanding.
        #expect(try store.load(record.sessionID)?.state == .launchingApp)
    }

    /// Writes `count` sessions with explicit, increasing modification dates so
    /// recency ordering is deterministic rather than dependent on filesystem
    /// timestamp resolution. Returns identifiers oldest to newest.
    private static func seedSessions(
        count: Int,
        in root: URL,
        store: SharedStore
    ) throws -> [UUID] {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        return try (0..<count).map { index in
            var record = SessionRecord()
            try record.transition(to: .launchingApp)
            try store.save(record)
            let file = sessions
                .appendingPathComponent(record.sessionID.uuidString.lowercased())
                .appendingPathExtension("json")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index))],
                ofItemAtPath: file.path
            )
            return record.sessionID
        }
    }

    @Test func insertionAddsOnlyNeededSpacing() {
        #expect(
            TextInsertion.preparedTranscript("hello", before: "Say", after: nil) == " hello"
        )
        #expect(
            TextInsertion.preparedTranscript("Hello.", before: nil, after: "Next") == "Hello. "
        )
        #expect(
            TextInsertion.preparedTranscript(",", before: "hello", after: " world") == ","
        )
    }

    @Test func quickDictationAvailabilityExpires() {
        let now = Date(timeIntervalSince1970: 1_000)
        let availability = QuickDictationAvailability(
            activatedAt: now,
            expiresAt: now.addingTimeInterval(600)
        )
        #expect(availability.isReady(at: now))
        #expect(!availability.isReady(at: now.addingTimeInterval(601)))
    }

    @Test func sharedStoreRoundTripsQuickDictationAvailability() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        let availability = QuickDictationAvailability(
            expiresAt: Date().addingTimeInterval(600)
        )

        try store.saveQuickDictationAvailability(availability)
        #expect(try store.loadQuickDictationAvailability() == availability)
        try store.clearQuickDictationAvailability()
        #expect(try store.loadQuickDictationAvailability() == nil)
    }

    /// These raw values are the gateway's wire contract; the server rejects
    /// anything outside its own literal set.
    @Test func writingStylesHaveStableGatewayValues() {
        #expect(WritingStyle.raw.rawValue == "raw")
        #expect(WritingStyle.clean.rawValue == "clean")
        #expect(WritingStyle.formal.rawValue == "formal")
        #expect(WritingStyle.casual.rawValue == "casual")
        #expect(WritingStyle.veryCasual.rawValue == "very_casual")
        #expect(WritingStyle.excited.rawValue == "excited")
        #expect(SessionRecord().style == WritingStyle.casual.rawValue)
        #expect(WritingStyle.allCases.count == 6)
    }

    @Test func everyWritingStyleIsPresentableInThePicker() {
        for style in WritingStyle.allCases {
            #expect(!style.displayName.isEmpty)
            #expect(!style.detail.isEmpty)
            #expect(!style.example.isEmpty)
            #expect(!style.symbolName.isEmpty)
        }
        #expect(WritingStyle.clean.example == "this is VocaPhone. it is a keyboard you talk to.")
        #expect(WritingStyle.formal.example == "This is VocaPhone. It is a keyboard you talk to.")
        #expect(WritingStyle.clean.example != WritingStyle.formal.example)
    }

    @Test func transcriptionLanguagesHaveStableGatewayValues() {
        #expect(TranscriptionLanguage.allCases.map(\.rawValue) == [
            "auto", "ar", "as", "bn", "bg", "yue", "ca", "hr", "cs", "da",
            "nl", "en", "et", "tl", "fi", "fr", "de", "el", "gu", "he",
            "hi", "hinglish_roman", "hu", "id", "it", "ja", "kn", "ko", "lv", "lt",
            "ms",
            "ml", "mt", "zh", "mr", "ne", "no", "fa", "pl", "pt", "pa",
            "ro", "ru", "sr", "sk", "sl", "es", "sw", "sv", "ta", "te",
            "th", "tr", "uk", "ur", "vi",
        ])
        #expect(SessionRecord().language == TranscriptionLanguage.automatic.rawValue)
    }

    /// An unsupported language routes a transcribing session straight to the
    /// permanent failure state. Retrying replays the same language against the
    /// same model, so the session must be terminal and must not offer Retry.
    @Test func anUnsupportedLanguageFailsPermanentlyAndCannotBeRetried() throws {
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try record.transition(to: .recording)
        try record.transition(to: .finalizing)
        try record.transition(to: .uploading)
        try record.transition(to: .transcribing)

        try record.transition(to: .transcriptionFailedPermanent)

        #expect(record.state.isTerminal)
        #expect(!record.canRetry)
    }

    @Test func microphonePreferencesHaveStableStoredValues() {
        #expect(MicrophonePreference.automatic.rawValue == "automatic")
        #expect(MicrophonePreference.iPhone.rawValue == "iphone")
    }

    @Test func gatewayEndpointAcceptsLANAndHTTPSHosts() {
        let lan = GatewayEndpoint.validatedURL(from: "  http://homelabone:8765/  ")
        let vps = GatewayEndpoint.validatedURL(from: "https://dictation.example.com")

        #expect(lan?.absoluteString == "http://homelabone:8765/")
        #expect(vps?.host == "dictation.example.com")
        #expect(lan.map(GatewayEndpoint.usesUnencryptedHTTP) == true)
        #expect(vps.map(GatewayEndpoint.usesUnencryptedHTTP) == false)
    }

    @Test func gatewayEndpointRejectsUnsupportedOrAmbiguousURLs() {
        #expect(GatewayEndpoint.validatedURL(from: "homelabone:8765") == nil)
        #expect(GatewayEndpoint.validatedURL(from: "ftp://homelabone/model") == nil)
        #expect(GatewayEndpoint.validatedURL(from: "https://user:password@example.com") == nil)
        #expect(GatewayEndpoint.validatedURL(from: "https://example.com?token=secret") == nil)
    }
}
