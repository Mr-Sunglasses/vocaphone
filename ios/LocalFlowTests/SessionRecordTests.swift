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

    @Test func writingStylesHaveStableGatewayValues() {
        #expect(WritingStyle.formal.rawValue == "formal")
        #expect(WritingStyle.casual.rawValue == "casual")
        #expect(WritingStyle.veryCasual.rawValue == "very_casual")
        #expect(WritingStyle.excited.rawValue == "excited")
        #expect(SessionRecord().style == WritingStyle.casual.rawValue)
    }
}
