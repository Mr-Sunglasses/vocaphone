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
        #expect(record.state == .recording)
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
    }

    @Test func transcriptionLanguagesHaveStableGatewayValues() {
        #expect(TranscriptionLanguage.allCases.map(\.rawValue) == [
            "auto", "ar", "as", "bn", "nl", "en", "fr", "de", "gu", "hi",
            "it", "ja", "kn", "ko", "ml", "zh", "mr", "ne", "pl", "pt",
            "pa", "ru", "es", "ta", "te", "uk", "ur", "vi",
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
