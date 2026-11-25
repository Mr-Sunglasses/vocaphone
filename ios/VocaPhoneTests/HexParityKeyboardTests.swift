import Foundation
import Testing
import UIKit

/// The typing and dictation behaviours brought over from Hex's iPhone keyboard:
/// each rule as a pure decision, so a regression fails here rather than on a
/// phone.
@MainActor
struct HexParityKeyboardTests {
    // MARK: Never-suggest list

    private static let list = OffensiveWords.parse("""
    # comment
    *\tslur\tslurword
    en\tswear\tdamnit
    en\tswear\tblow job
    es\tswear\tsoloenespanol
    """)

    @Test func slursAreNeverOfferedAndSwearsOnlyWhenAllowed() {
        #expect(Self.list.blocks("slurword", allowSwears: true))
        #expect(Self.list.blocks("Slurword", allowSwears: false))
        #expect(Self.list.blocks("damnit", allowSwears: false))
        #expect(!Self.list.blocks("damnit", allowSwears: true))
        #expect(!Self.list.blocks("hello", allowSwears: false))
    }

    @Test func otherLanguagesRowsAreIgnored() {
        #expect(!Self.list.blocks("soloenespanol", allowSwears: false))
    }

    @Test func anExpressionBlocksOnlyThePair() {
        #expect(!Self.list.blocks("job", allowSwears: false))
        #expect(Self.list.blocks("job", after: "blow", allowSwears: false))
        #expect(Self.list.blocks("blow job", allowSwears: false))
        #expect(Self.list.filter(["job", "jobs"], after: "blow", allowSwears: false) == ["jobs"])
    }

    @Test func theShippedListLoadsAndBlocksEnglishSlurs() throws {
        // Read from the repository, as the accuracy benchmark reads en.txt:
        // the test bundle has no host app carrying the keyboard's resources.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("assets/keyboard/never-suggest.tsv")
        let words = OffensiveWords.parse(try String(contentsOf: url, encoding: .utf8))
        #expect(!words.isEmpty)
        #expect(words.blocks("faggot", allowSwears: true))
        #expect(!words.blocks("keyboard", allowSwears: false))
    }

    @Test func aTypedOffensiveWordIsNeverCorrected() {
        var context = TypingCandidates.Context()
        context.composition = "damnitt"
        context.typedIsOffensive = true
        context.hasCheckerAnswer = true
        context.systemGuesses = ["dammit"]
        #expect(TypingCandidates.autocorrectDecision(context).replacement == nil)
    }

    // MARK: Learned fixes

    @Test func aTypoFixedTheSameWayTwiceIsLearned() {
        var learned = LearnedWords()
        learned.noteFix(typo: "Ciry", fix: "City")
        #expect(learned.learnedFix(for: "ciry") == nil)
        learned.noteFix(typo: "ciry", fix: "city")
        #expect(learned.learnedFix(for: "Ciry") == "city")
        #expect(learned.learnedFixCount == 1)
    }

    @Test func aTypoFixedTwoWaysOrTurnedDownIsNeverApplied() {
        var twoWays = LearnedWords()
        twoWays.noteFix(typo: "hte", fix: "the")
        twoWays.noteFix(typo: "hte", fix: "hate")
        twoWays.noteFix(typo: "hte", fix: "the")
        #expect(twoWays.learnedFix(for: "hte") == nil)

        var rejected = LearnedWords()
        rejected.noteFix(typo: "ciry", fix: "city")
        rejected.noteFix(typo: "ciry", fix: "city")
        rejected.rejectFix(typo: "ciry")
        #expect(rejected.learnedFix(for: "ciry") == nil)
    }

    @Test func learnedFixesSurviveEncodingAndOlderFilesStillDecode() throws {
        var learned = LearnedWords()
        learned.noteFix(typo: "ciry", fix: "city")
        learned.noteFix(typo: "ciry", fix: "city")
        let decoded = try JSONDecoder().decode(LearnedWords.self, from: JSONEncoder().encode(learned))
        #expect(decoded.learnedFix(for: "ciry") == "city")
        let old = try JSONDecoder().decode(LearnedWords.self, from: Data(#"{"entries":{}}"#.utf8))
        #expect(old.learnedFix(for: "ciry") == nil)
    }

    @Test func spaceAppliesALearnedFixButNotOverARealWord() {
        var context = TypingCandidates.Context()
        context.composition = "Ciry"
        context.learnedFix = "city"
        #expect(TypingCandidates.autocorrectDecision(context).replacement == "City")
        context.isKnownToChecker = true
        #expect(TypingCandidates.autocorrectDecision(context).replacement == nil)
        #expect(TypingCandidates.rankedSuggestions(context).first == "City")
    }

    @Test func onlyASlipOfTheFingersCountsAsAFix() {
        let rows = TypingLayout.fallback.rows
        #expect(TypingEngine.isSlip("ciry", of: "city", rows: rows))
        #expect(TypingEngine.isSlip("Im", of: "I'm", rows: rows))
        #expect(TypingEngine.isSlip("teh", of: "the", rows: rows))
        #expect(!TypingEngine.isSlip("sunda", of: "saturday", rows: rows))
        #expect(!TypingEngine.isSlip("cat", of: "dog", rows: rows))
        #expect(!TypingEngine.isSlip("a", of: "an", rows: rows))
    }

    // MARK: Where the fingers landed

    @Test func aTapOnTheEdgeTowardTheMeantKeyFavoursIt() {
        let rows = TypingLayout.fallback.rows
        // "r" pressed past its own edge, in the part of "t" the hit map lent
        // it (a likelier next letter claims a neighbour's border): "the".
        let towardT: [TapOffset?] = [TapOffset(dx: 0.7, dy: 0), nil, nil]
        let centred: [TapOffset?] = [TapOffset(dx: 0, dy: 0), nil, nil]
        let favoured = TapSpatialScore.adjustment(typed: "rhe", candidate: "the", taps: towardT, rows: rows)
        let disfavoured = TapSpatialScore.adjustment(typed: "rhe", candidate: "the", taps: centred, rows: rows)
        #expect(favoured < 0)
        #expect(disfavoured > 0)
        #expect(abs(disfavoured) <= TapSpatialScore.perLetterCap)
    }

    @Test func positionSettlesATieTheSpellingCannot() {
        let rows = TypingLayout.fallback.rows
        // "hend": one edit from "hand" and from "bend". An "h" pressed low and
        // left, toward "b", says which.
        let taps: [TapOffset?] = [TapOffset(dx: -0.3, dy: 0.45), nil, nil, nil]
        var context = TypingCandidates.Context()
        context.composition = "hend"
        context.tapOffsets = taps
        let towardB = TypingCandidates.correctionCost(typed: "hend", candidate: "bend", context: context)
        let towardA = TypingCandidates.correctionCost(typed: "hend", candidate: "hand", context: context)
        #expect(towardB < towardA)
        #expect(TapSpatialScore.adjustment(typed: "hend", candidate: "hands", taps: taps, rows: rows) == 0)
    }

    // MARK: Strip, accents, delete, trackpad

    @Test func theStripLowerHalfBelongsToTheKeysOnlyWhileTyping() {
        let bar = CGRect(x: 0, y: 0, width: 390, height: 44)
        #expect(KeyGridView.stripTouchGoesToKeys(y: 30, bar: bar, isTyping: true))
        #expect(!KeyGridView.stripTouchGoesToKeys(y: 10, bar: bar, isTyping: true))
        #expect(!KeyGridView.stripTouchGoesToKeys(y: 30, bar: bar, isTyping: false))
        let panel = CGRect(x: 0, y: 0, width: 390, height: 220)
        #expect(!KeyGridView.stripTouchGoesToKeys(y: 200, bar: panel, isTyping: true))
    }

    @Test func quickAccentsPreselectTheMainAccentOfLettersOnly() {
        #expect(KeyAlternativesView.initialIndex(for: ["e", "é", "è"], quickAccents: true) == 1)
        #expect(KeyAlternativesView.initialIndex(for: ["e", "é", "è"], quickAccents: false) == 0)
        #expect(KeyAlternativesView.initialIndex(for: ["-", "–", "—"], quickAccents: true) == 0)
        #expect(KeyAlternativesView.initialIndex(for: ["e"], quickAccents: true) == 0)
    }

    @Test func aDeleteSlideDeletesAWordPerKeyWidth() {
        #expect(DeleteWordSlide.wordsWanted(startX: 300, x: 290, step: 32) == 0)
        #expect(DeleteWordSlide.wordsWanted(startX: 300, x: 268, step: 32) == 1)
        #expect(DeleteWordSlide.wordsWanted(startX: 300, x: 200, step: 32) == 3)
        #expect(DeleteWordSlide.wordsWanted(startX: 300, x: 340, step: 32) == 0)
    }

    @Test func theTrackpadMovesBetweenLinesKeepingTheColumn() {
        let text = "first line\nsecond line\nthird"
        let cursor = ("first line\nsecon" as String).utf16.count
        let up = CursorLineMove.offset(text: text, position: cursor, lines: -1, charactersPerRow: 40)
        #expect(up == -11)
        let down = CursorLineMove.offset(text: text, position: cursor, lines: 1, charactersPerRow: 40)
        // Column 5 of "second line" lands at the end of the shorter "third".
        #expect(down == 12)
        #expect(CursorLineMove.offset(text: text, position: cursor, lines: -5, charactersPerRow: 40) == -11)
        #expect(CursorLineMove.offset(text: "one row", position: 3, lines: 1, charactersPerRow: 40) == 0)
    }

    @Test func longLinesWrapIntoRows() {
        let text = String(repeating: "a", count: 25)
        #expect(CursorLineMove.offset(text: text, position: 22, lines: -1, charactersPerRow: 10) == -10)
    }

    @Test func aFasterFingerCrossesMoreLines() {
        #expect(CursorTrackpad.lineGain(atSpeed: 0) == 1)
        #expect(abs(CursorTrackpad.lineGain(atSpeed: 400) - 1.4) < 0.001)
        #expect(abs(CursorTrackpad.lineGain(atSpeed: 1000) - 2) < 0.001)
        #expect(CursorTrackpad.lineGain(atSpeed: 5000) == 2.6)
    }

    // MARK: Empty-field chips

    @Test func emptyFieldsOfferWhatOnlyTheyNeed() {
        #expect(FieldOffer.decide(fieldIsEmpty: true, contentType: .oneTimeCode, hasFullAccess: false,
                                  hasRecentUnpastedCopy: false) == .oneTimeCode)
        #expect(FieldOffer.decide(fieldIsEmpty: true, contentType: .password, hasFullAccess: true,
                                  hasRecentUnpastedCopy: true) == .passwords)
        #expect(FieldOffer.decide(fieldIsEmpty: true, contentType: nil, hasFullAccess: true,
                                  hasRecentUnpastedCopy: true) == .paste)
        #expect(FieldOffer.decide(fieldIsEmpty: true, contentType: nil, hasFullAccess: false,
                                  hasRecentUnpastedCopy: true) == nil)
        #expect(FieldOffer.decide(fieldIsEmpty: false, contentType: .oneTimeCode, hasFullAccess: true,
                                  hasRecentUnpastedCopy: true) == nil)
    }

    @Test func aCopyIsOfferedOnceAndOnlyWhileRecent() throws {
        let suite = "hex-parity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date()
        #expect(ClipboardWatch.hasRecentUnpastedCopy(changeCount: 7, hasStrings: true, defaults: defaults, now: start))
        #expect(!ClipboardWatch.hasRecentUnpastedCopy(changeCount: 7, hasStrings: false, defaults: defaults, now: start))
        #expect(!ClipboardWatch.hasRecentUnpastedCopy(
            changeCount: 7, hasStrings: true, defaults: defaults,
            now: start.addingTimeInterval(FieldOffer.recentCopyWindow + 1)
        ))
        #expect(ClipboardWatch.hasRecentUnpastedCopy(changeCount: 8, hasStrings: true, defaults: defaults, now: start))
        ClipboardWatch.notePasted(changeCount: 8, defaults: defaults)
        #expect(!ClipboardWatch.hasRecentUnpastedCopy(changeCount: 8, hasStrings: true, defaults: defaults, now: start))
    }

    // MARK: Dictation

    @Test func aTranscriptInsertsItselfOnlyWhileFresh() {
        let ready = SessionRecord(now: Date())
        #expect(PendingTranscriptPolicy.autoInserts(ready, preference: true))
        #expect(!PendingTranscriptPolicy.autoInserts(
            ready, preference: true,
            now: Date().addingTimeInterval(PendingTranscriptPolicy.autoInsertWindow + 2)
        ))
        #expect(SessionExpiryPolicy.window(for: .targetContextChanged) == SessionExpiryPolicy.transcriptOfferWindow)
        #expect(SessionExpiryPolicy.window(for: .uploadFailedRecoverable) == SessionExpiryPolicy.pendingUserActionWindow)
    }

    @Test func onlyTheSelectionADictationStartedOverIsReplaced() {
        let id = UUID()
        let recorded = InsertionTargetFingerprint.selection(
            sessionID: id, selected: "old words", before: "Keep ", after: " here"
        )
        let same = InsertionTargetFingerprint.selection(
            sessionID: id, selected: "old words", before: "Keep ", after: " here"
        )
        let other = InsertionTargetFingerprint.selection(
            sessionID: id, selected: "other", before: "Keep ", after: " here"
        )
        #expect(InsertionTargetFingerprint.mayReplaceSelection(recorded: recorded, current: same))
        #expect(!InsertionTargetFingerprint.mayReplaceSelection(recorded: recorded, current: other))
        #expect(!InsertionTargetFingerprint.mayReplaceSelection(recorded: nil, current: other))
        // Nothing selected now: the words go in at the cursor.
        #expect(InsertionTargetFingerprint.mayReplaceSelection(recorded: recorded, current: nil))
        #expect(InsertionTargetFingerprint.selection(sessionID: id, selected: "", before: nil, after: nil) == nil)
    }

    @Test func theIPhoneMicrophoneIsTheDefault() {
        #expect(MicrophonePreference.default == .iPhone)
    }
}
