import Foundation
import Testing

/// Following a dictation through the user's edits, from what the keyboard
/// reads around the cursor. The same cases as `CorrectionWatchTest.kt`.
struct CorrectionWatchTests {
    private func watching(_ inserted: String) -> CorrectionWatch {
        let watch = CorrectionWatch(isKnownWord: CorrectionLearnerTests.isKnown)
        #expect(watch.start(inserted))
        return watch
    }

    private func pairs(_ found: [LearnedCorrection]) -> [String] {
        found.map { "\($0.heard)→\($0.corrected)" }
    }

    @Test func learnsAFixMadeInTheMiddleOfAShortMessage() {
        let watch = watching("ask Namratha about it ")
        watch.read(before: "ask Namratha about it ", after: "")
        // The cursor moved back into the name and one letter went.
        watch.read(before: "ask Namrata", after: " about it ")
        let found = watch.finish()
        #expect(pairs(found) == ["Namratha→Namrata"])
        #expect(found.first?.heardIsWord == false)
        #expect(found.first?.namesTerm == true)
        #expect(!watch.isActive)
    }

    @Test func keepsTheFixWhenTheMessageIsSentAndTheFieldCleared() {
        let watch = watching("ask Namratha about it")
        watch.read(before: "ask Namratha about it", after: "")
        watch.read(before: "ask Namrata about it", after: "")
        watch.read(before: "", after: "")
        #expect(pairs(watch.finish()) == ["Namratha→Namrata"])
    }

    @Test func theLastReadingThatFindsTheDictationWins() {
        let watch = watching("ask Namratha about it")
        watch.read(before: "ask Namratha about it", after: "")
        // Half-way through retyping the name, then done.
        watch.read(before: "ask Namrat", after: " about it")
        watch.read(before: "ask Namrata", after: " about it")
        #expect(pairs(watch.finish()) == ["Namratha→Namrata"])
    }

    @Test func undoingAFixUnlearnsIt() {
        let watch = watching("ask Namratha about it")
        watch.read(before: "ask Namratha about it", after: "")
        watch.read(before: "ask Namrata about it", after: "")
        watch.read(before: "ask Namratha about it", after: "")
        #expect(watch.finish().isEmpty)
    }

    @Test func writingOnAfterAFixKeepsIt() {
        let watch = watching("ask Namratha about it")
        watch.read(before: "ask Namratha about it", after: "")
        watch.read(before: "ask Namrata about it and the report", after: "")
        #expect(pairs(watch.finish()) == ["Namratha→Namrata"])
    }

    @Test func findsADictationInTheMiddleOfALongFieldFromPartialReadings() {
        let earlier = String(repeating: "Notes from Monday. ", count: 20)
        let inserted = "please ask Namratha about it"
        let later = String(repeating: " Then we ship on Friday. ", count: 10)
        let watch = watching(inserted)
        // Just after the insertion: the cursor at its end, neither side reaching the field's ends.
        watch.read(
            before: String(earlier.suffix(60)) + inserted, after: String(later.prefix(60)),
            reachesStart: false, reachesEnd: false
        )
        // The cursor moved into the name; the window moved with it.
        let edited = Array(earlier + "please ask Namrata about it" + later)
        let name = Array(earlier + "please ask ").count
        let cursor = name + 4
        watch.read(
            before: String(edited[(cursor - 50)..<cursor]), after: String(edited[cursor..<(cursor + 50)]),
            reachesStart: false, reachesEnd: false
        )
        #expect(pairs(watch.finish()) == ["Namratha→Namrata"])
    }

    @Test func givesUpWhereTheDictationCannotBeToldApart() {
        let span = DictatedSpan(
            dictated: "ask Namratha", before: "Re: ", after: ".", beforeIsFieldStart: false, afterIsFieldEnd: false
        )
        // Two copies with different text between the same anchors.
        #expect(span.edited(in: "Re: ask Namrata. Re: ask Namrita.", reachesStart: true, reachesEnd: true) == nil)
        // Two copies saying the same thing are one answer.
        #expect(span.edited(in: "Re: ask Namrata. Re: ask Namrata.", reachesStart: true, reachesEnd: true) == "ask Namrata")
        // An anchor is gone.
        #expect(span.edited(in: "Fwd: ask Namrata.", reachesStart: true, reachesEnd: true) == nil)
    }

    @Test func aFieldAnchorNeedsAReadingThatReachesTheFieldsEnd() {
        let span = DictatedSpan(
            dictated: "ask Namratha", before: "", after: "", beforeIsFieldStart: true, afterIsFieldEnd: true
        )
        #expect(span.edited(in: "ask Namrata", reachesStart: true, reachesEnd: true) == "ask Namrata")
        #expect(span.edited(in: "ask Namrata", reachesStart: false, reachesEnd: true) == nil)
    }

    @Test func aFieldThatMovedOnIsNotLearnedFrom() {
        let watch = watching("ask Namratha about it")
        watch.read(before: "ask Namratha about it", after: "")
        // Sent, then a new message in the same field.
        watch.read(before: "ok", after: "")
        #expect(watch.finish().isEmpty)
    }

    @Test func rewordingTeachesNothing() {
        let watch = watching("put it there please")
        watch.read(before: "put it there please", after: "")
        watch.read(before: "put it their please", after: "")
        #expect(watch.finish().isEmpty)
    }

    @Test func anOrdinaryWordFixedToANameIsMarkedAsAWord() {
        let watch = watching("ask cloud about it")
        watch.read(before: "ask cloud about it", after: "")
        watch.read(before: "ask Claude about it", after: "")
        let found = watch.finish()
        #expect(pairs(found) == ["cloud→Claude"])
        #expect(found.first?.heardIsWord == true)
        #expect(found.first?.namesTerm == true)
    }

    @Test func textInAnotherLanguageIsNotFollowed() {
        #expect(!CorrectionWatch(isKnownWord: CorrectionLearnerTests.isKnown).start("frag Namratha danach bitte"))
        #expect(!CorrectionWatch(isKnownWord: CorrectionLearnerTests.isKnown).start("   "))
    }

    @Test func aDictationNotAtTheCursorAfterInsertionIsDropped() {
        let watch = watching("ask Namratha about it")
        watch.read(before: "something else entirely", after: "")
        #expect(!watch.isActive)
        watch.read(before: "ask Namrata about it", after: "")
        #expect(watch.finish().isEmpty)
    }

    @Test func aSpaceAfterTheDictationStillFindsItsBaseline() {
        let span = DictatedSpan.baseline(
            dictated: "ask Namratha", before: "Hi. ask Namratha ", after: " Bye", reachesStart: true, reachesEnd: true
        )
        #expect(span?.before == "Hi. ")
        #expect(span?.after == "  Bye")
        #expect(DictatedSpan.baseline(
            dictated: "ask Namratha", before: "ask Namratha and more", after: "", reachesStart: true, reachesEnd: true
        ) == nil)
    }

    // MARK: - The keyboard's side

    @Test func theKeyboardObserverHandsOverOnlyThePairs() {
        let box = DeliveredBox()
        let observer = DictationCorrectionObserver { box.append($0) }
        let words = TypingWordList(words: Array(CorrectionLearnerTests.common), bigrams: [:])
        observer.dictationInserted(" ask Namratha about it", before: "Hi.", after: "", wordList: words)
        #expect(observer.isActive)
        observer.fieldRead(before: "Hi. ask Namrata", after: " about it")
        // iOS not answering says nothing.
        observer.fieldRead(before: nil, after: nil)
        observer.drain()
        #expect(box.values.isEmpty)
        observer.finish()
        observer.drain()
        #expect(!observer.isActive)
        #expect(box.values.map(pairs) == [["Namratha→Namrata"]])
        // Nothing followed, nothing handed over.
        observer.fieldRead(before: "Hi. ask Namrita", after: " about it")
        observer.finish()
        observer.drain()
        #expect(box.values.count == 1)
    }
}

/// What the observer delivered, from its queue.
private final class DeliveredBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[LearnedCorrection]] = []

    var values: [[LearnedCorrection]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ found: [LearnedCorrection]) {
        lock.lock()
        stored.append(found)
        lock.unlock()
    }
}
