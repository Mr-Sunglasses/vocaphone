import Foundation
import Testing

/// The fingerprint that keeps a transcript in the app it was dictated in, and
/// the decision the keyboard makes with it.
struct InsertionTargetFingerprintTests {
    private let session = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test func theSameFieldProducesTheSameFingerprint() {
        let started = InsertionTargetFingerprint.make(
            sessionID: session, before: "See you at", after: ""
        )
        let returned = InsertionTargetFingerprint.make(
            sessionID: session, before: "See you at", after: ""
        )
        #expect(started != nil)
        #expect(InsertionTargetFingerprint.compare(recorded: started, current: returned) == .same)
    }

    /// Dictate in Messages, switch to Notes while it transcribes: the text
    /// around the cursor is not the same, and that is the evidence.
    @Test func anotherFieldIsADifferentFingerprint() {
        let messages = InsertionTargetFingerprint.make(
            sessionID: session, before: "See you at", after: ""
        )
        let notes = InsertionTargetFingerprint.make(
            sessionID: session, before: "Shopping list\n- eggs\n", after: ""
        )
        let emptyNote = InsertionTargetFingerprint.make(sessionID: session, before: "", after: "")
        #expect(InsertionTargetFingerprint.compare(recorded: messages, current: notes) == .different)
        #expect(InsertionTargetFingerprint.compare(recorded: messages, current: emptyNote) == .different)
    }

    /// The record lives in the App Group; the words the user was typing are not
    /// the keyboard's to keep there.
    @Test func theFingerprintNeverContainsTheText() throws {
        let fingerprint = try #require(InsertionTargetFingerprint.make(
            sessionID: session, before: "my secret plan", after: "is here"
        ))
        #expect(fingerprint.count == 16)
        #expect(fingerprint.allSatisfy { $0.isHexDigit })
        for word in ["secret", "plan", "here"] {
            #expect(!fingerprint.contains(word))
        }
    }

    /// Salted by session, so the same text in two dictations cannot be matched
    /// up by anyone reading the container.
    @Test func theSameTextInAnotherSessionHashesDifferently() {
        let first = InsertionTargetFingerprint.make(sessionID: session, before: "Hi", after: nil)
        let second = InsertionTargetFingerprint.make(sessionID: UUID(), before: "Hi", after: nil)
        #expect(first != second)
    }

    /// iOS bounds the context it gives a keyboard, and may bound it differently
    /// on a second read. Only the text nearest the cursor counts.
    @Test func onlyTheTextNearestTheCursorCounts() {
        let tail = String(repeating: "x", count: InsertionTargetFingerprint.contextLength)
        let long = InsertionTargetFingerprint.make(
            sessionID: session, before: "An earlier paragraph. " + tail, after: nil
        )
        let bounded = InsertionTargetFingerprint.make(sessionID: session, before: tail, after: nil)
        #expect(long == bounded)
    }

    /// No answer from iOS is not an empty field. It is no evidence at all.
    @Test func anUnreadFieldHasNoFingerprint() {
        #expect(InsertionTargetFingerprint.make(sessionID: session, before: nil, after: nil) == nil)
        #expect(InsertionTargetFingerprint.make(sessionID: session, before: "", after: nil) != nil)
        let recorded = InsertionTargetFingerprint.make(sessionID: session, before: "a", after: nil)
        #expect(InsertionTargetFingerprint.compare(recorded: recorded, current: nil) == .unknown)
    }

    /// A record written before the fingerprint existed — or one started where
    /// the field could not be read — keeps the behaviour it always had.
    @Test func aRecordWithoutAFingerprintMatchesAnyField() {
        #expect(InsertionTargetFingerprint.compare(recorded: nil, current: "0011") == .same)
        #expect(InsertionTargetFingerprint.compare(recorded: nil, current: nil) == .same)
    }

    // MARK: - What the keyboard does

    private func action(
        _ state: SessionState,
        target: InsertionTargetFingerprint.Match = .same,
        sameDocument: Bool = true,
        interrupted: Bool = false,
        autoInsert: Bool = true
    ) -> PendingTranscriptPolicy.Action {
        PendingTranscriptPolicy.action(
            for: state,
            target: target,
            sameDocument: sameDocument,
            interrupted: interrupted,
            autoInsert: autoInsert
        )
    }

    @Test func aTranscriptBackInItsOwnFieldInsertsItself() {
        #expect(action(.readyToInsert) == .insert)
        #expect(action(.readyToInsert, autoInsert: false) == .offer)
    }

    /// The bug: a keyboard adopting the session in another app treated that
    /// app's field as the target and inserted.
    @Test func aTranscriptAdoptedInAnotherAppParksInsteadOfInserting() {
        #expect(action(.readyToInsert, target: .different) == .park)
        #expect(action(.readyToInsert, target: .different, autoInsert: false) == .park)
        // And stays parked there.
        #expect(action(.targetContextChanged, target: .different) == .offer)
    }

    @Test func returningToTheOriginalFieldRearmsAParkedTranscript() {
        #expect(action(.targetContextChanged) == .rearm)
        #expect(action(.targetContextChanged, sameDocument: false) == .offer)
    }

    /// The interrupted insertion may itself have changed the text around the
    /// cursor, so a mismatch is expected in the very field it was dictated
    /// for. Parking it would swap the "may have been interrupted" warning for
    /// "Insert in this field" and invite a duplicate.
    @Test func anInterruptedInsertionKeepsItsWarningInsteadOfParking() {
        #expect(action(.readyToInsert, target: .different, interrupted: true) == .offer)
        #expect(action(.readyToInsert, target: .unknown, interrupted: true) == .offer)
        #expect(action(.readyToInsert, sameDocument: false, interrupted: true) == .offer)
    }

    /// The cursor moved while the keyboard watched: the guard that existed
    /// before the fingerprint still applies.
    @Test func aWatchedMoveToAnotherFieldStillParks() {
        #expect(action(.readyToInsert, sameDocument: false) == .park)
    }

    /// Until the field can be read there is no evidence either way: the
    /// transcript waits behind Insert, neither inserted nor parked.
    @Test func anUnreadFieldWaitsForATap() {
        #expect(action(.readyToInsert, target: .unknown) == .offer)
        #expect(action(.targetContextChanged, target: .unknown) == .offer)
    }

    /// The text may already be in the field. A duplicate is worse than a tap.
    @Test func anInterruptedInsertionIsNeverInsertedAutomatically() {
        #expect(action(.readyToInsert, interrupted: true) == .offer)
    }

    /// A Shortcuts or Action button dictation has no field of its own. It
    /// waits behind Insert in the next field rather than going into whichever
    /// one the keyboard happens to appear in.
    @Test func aShortcutDictationIsOfferedRatherThanInserted() {
        var shortcut = SessionRecord(sourceDocumentID: SessionOrigin.shortcut)
        #expect(shortcut.isFromShortcut)
        #expect(!PendingTranscriptPolicy.autoInserts(shortcut, preference: true))
        shortcut.sourceDocumentID = "C3A1F2E4-0000-0000-0000-000000000000"
        #expect(!shortcut.isFromShortcut)
        #expect(PendingTranscriptPolicy.autoInserts(shortcut, preference: true))
        #expect(!PendingTranscriptPolicy.autoInserts(shortcut, preference: false))

        let fromShortcut = SessionRecord(sourceDocumentID: SessionOrigin.shortcut)
        #expect(action(
            .readyToInsert,
            autoInsert: PendingTranscriptPolicy.autoInserts(fromShortcut, preference: true)
        ) == .offer)
    }

    /// The keyboard skips microphone tests, and a Shortcuts dictation must not
    /// be mistaken for one.
    @Test func aShortcutIsNotAMicrophoneTest() {
        #expect(SessionOrigin.shortcut != SessionOrigin.microphoneTest)
        #expect(SessionOrigin.microphoneTest == "in-app-test")
    }

    @Test func otherStatesAreOnlyShown() {
        for state in SessionState.allCases
        where ![.readyToInsert, .targetContextChanged].contains(state) {
            #expect(action(state) == .offer)
        }
    }
}
