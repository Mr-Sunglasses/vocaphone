import Foundation
import Testing

/// VocaMac's `CorrectionLearnerTests` and `SentenceStartCorrectionTests`,
/// ported. The same cases as `CorrectionLearnerTest.kt`.
struct CorrectionLearnerTests {
    /// VocaMac's `TestWords.common`, plus the few words these cases add.
    static let common: Set<String> = [
        "the", "a", "an", "and", "i", "to", "is", "it", "in", "on", "of", "for", "with", "my", "me",
        "open", "file", "hello", "world", "cloud", "there", "their", "big", "large", "meet", "at",
        "send", "email", "call", "please", "user", "id", "kaiser", "service", "super", "base", "post", "apple",
        "notes", "mail", "check", "this", "that", "we", "should", "use", "set", "value", "ask",
        "about", "project", "today", "tomorrow", "update", "code", "run", "tests", "get", "hub",
        "put", "push", "hi", "see", "you", "five", "sounds", "good", "dear",
    ]

    static func isKnown(_ word: String) -> Bool { common.contains(word.lowercased()) }

    private func learn(
        _ inserted: String, before: String, after: String, caret: Int? = nil
    ) -> [CorrectionLearner.Correction] {
        CorrectionLearner.corrections(
            inserted: inserted, before: before, after: after, caretLocation: caret, isKnownWord: Self.isKnown
        )
    }

    private func correction(_ heard: String, _ corrected: String) -> CorrectionLearner.Correction {
        CorrectionLearner.Correction(heard: heard, corrected: corrected)
    }

    @Test func learnsANameSpellingFix() {
        let found = learn("ask Namratha about it", before: "Hi. ask Namratha about it", after: "Hi. ask Namrata about it")
        #expect(found == [correction("Namratha", "Namrata")])
    }

    @Test func learnsCasingAndJoiningFixes() {
        #expect(learn("push to git hub", before: "push to git hub", after: "push to GitHub") == [correction("git hub", "GitHub")])
        #expect(learn("push to github", before: "push to github", after: "push to GitHub") == [correction("github", "GitHub")])
    }

    @Test func sentenceCapitalizationIsNotATerm() {
        #expect(learn("hello world", before: "hello world", after: "Hello world").isEmpty)
    }

    @Test func aCommonWordSwapIsIgnored() {
        #expect(learn("put it there", before: "put it there", after: "put it their").isEmpty)
    }

    @Test func rewordingIsIgnored() {
        #expect(learn("that is big", before: "that is big", after: "that is large").isEmpty)
    }

    @Test func anEditOutsideTheDictationIsIgnored() {
        #expect(learn("ask Namratha", before: "Dear Bobb, ask Namratha", after: "Dear Bob, ask Namratha").isEmpty)
    }

    @Test func textNotFoundIsIgnored() {
        #expect(learn("something else", before: "hello", after: "hullo").isEmpty)
    }

    @Test func theCaretPicksTheCopyJustTyped() {
        let before = "ask Namratha. ask Namratha"
        let after = "ask Namratha. ask Namrata"
        #expect(learn("ask Namratha", before: before, after: after, caret: before.count) == [correction("Namratha", "Namrata")])
        // A caret at the first copy means the second edit wasn't in the dictation.
        #expect(learn("ask Namratha", before: before, after: after, caret: 12).isEmpty)
    }

    @Test func aLargeRewriteIsIgnored() {
        let inserted = "one two three four five six seven eight nine ten eleven twelve thirteen"
        let after = "uno dos tres cuatro cinco seis siete ocho nueve diez once doce trece"
        #expect(learn(inserted, before: inserted, after: after).isEmpty)
    }

    // MARK: - Sentence starts (VocaMac's SentenceStartCorrectionTests)

    private static let sentenceWords: Set<String> = [
        "whether", "weather", "is", "nice", "their", "there", "going", "home", "ask", "about", "it",
    ]

    private func learnSentence(_ text: String, edited: String, prefix: String = "") -> [CorrectionLearner.Correction] {
        CorrectionLearner.corrections(inserted: text, before: prefix + text, after: prefix + edited) {
            Self.sentenceWords.contains($0.lowercased())
        }
    }

    @Test func aSentenceStartCapitalIsNotAName() {
        #expect(learnSentence("Whether is nice.", edited: "Weather is nice.").isEmpty)
        #expect(learnSentence("Their going home.", edited: "There going home.").isEmpty)
        #expect(learnSentence("Whether is nice.", edited: "Weather is nice.", prefix: "Hi. ").isEmpty)
        #expect(learnSentence("ok. Whether is nice.", edited: "ok. Weather is nice.").isEmpty)
    }

    @Test func aNameAtASentenceStartIsStillLearned() {
        #expect(learnSentence("Pria is nice.", edited: "Priya is nice.") == [correction("Pria", "Priya")])
    }

    @Test func aCapitalMidSentenceCountsAsAName() {
        #expect(learnSentence("ask pria about it", edited: "ask Priya about it") == [correction("pria", "Priya")])
    }

    // MARK: - What the dictation became (VocaMac's DictationEditReader cases)

    @Test func aShortFixIsStillTheDictation() {
        #expect(CorrectionLearner.isStillDictation("Priya", of: "Pria"))
    }

    @Test func aFieldThatMovedOnIsNotTheDictation() {
        #expect(!CorrectionLearner.isStillDictation("ok", of: "Sounds good, see you at five"))
        #expect(!CorrectionLearner.isStillDictation("ok", of: "hello there"))
        #expect(!CorrectionLearner.isStillDictation("", of: "hello there"))
        #expect(CorrectionLearner.isStillDictation("Sounds good, see you at 5", of: "Sounds good, see you at five"))
    }

    // MARK: - Phone additions

    @Test func onlyTextInTheWordListsLanguageIsLearnedFrom() {
        #expect(CorrectionLearner.readsAsKnownLanguage("ask Namratha about it", isKnownWord: Self.isKnown))
        #expect(!CorrectionLearner.readsAsKnownLanguage("frag Namratha danach bitte", isKnownWord: Self.isKnown))
        #expect(!CorrectionLearner.readsAsKnownLanguage("123 456", isKnownWord: Self.isKnown))
    }

    @Test func tellsOrdinaryWordsAndTermsApart() {
        #expect(CorrectionLearner.isOrdinaryWord("cloud", isKnownWord: Self.isKnown))
        #expect(!CorrectionLearner.isOrdinaryWord("get hub", isKnownWord: Self.isKnown))
        #expect(!CorrectionLearner.isOrdinaryWord("Namratha", isKnownWord: Self.isKnown))
        #expect(CorrectionLearner.namesATerm("Claude", isKnownWord: Self.isKnown))
        #expect(CorrectionLearner.namesATerm("kubectl", isKnownWord: Self.isKnown))
        #expect(!CorrectionLearner.namesATerm("there", isKnownWord: Self.isKnown))
    }
}
