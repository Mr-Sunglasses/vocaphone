import Foundation
import Testing

/// Where Apple's checkers' edits land in the Writing check screen: only on
/// words that are in the text, only small changes, never over something
/// already found or the user's own words.
struct AppleProofreadingTests {
    private static let rules = WritingCheckTests.rules

    private func edit(
        _ original: String, _ replacement: String, _ reason: String = "Why.", sentence: String = "",
        in piece: Range<Int> = 0..<Int.max
    ) -> (AppleProofreading.Edit, Range<Int>) {
        (AppleProofreading.Edit(original: original, replacement: replacement, reason: reason, sentence: sentence), piece)
    }

    @Test func generatedEditsLandOnTheirWordsInOrder() {
        let text = "She go to the store and she go home."
        let found = AppleProofreading.suggestions(text, [
            edit("go", "goes", sentence: text), edit("go", "goes", sentence: text),
        ], rules: Self.rules)
        #expect(found.map(\.start) == [4, 28])
        #expect(found.allSatisfy { $0.kind == "deep_check" && $0.source == .generated && !$0.mechanical })
        #expect(found.first?.message == "Why.")
        #expect(WritingCheck.apply(text, found[0]) == "She goes to the store and she go home.")
    }

    @Test func editsThatAreNotSmallOrNotThereAreDropped() {
        let text = "I has a cat."
        let found = AppleProofreading.suggestions(text, [
            edit("dog", "cat"),                                   // not in the text
            edit("has", "has"),                                   // no change
            edit("I has a cat.", "I have a cat that is very nice."), // a rewrite
            edit("as", "is"),                                      // inside a word
            edit("has", "have"),
        ], rules: Self.rules)
        #expect(found.map(\.label) == ["has → have"])
    }

    @Test func anEditLandsInTheSentenceItNames() {
        let text = "They go home. She go home."
        let named = AppleProofreading.suggestions(text, [edit("go", "goes", sentence: "She go home.")], rules: Self.rules)
        #expect(named.map(\.start) == [18])
        // Without its sentence, words that are there twice could be either.
        #expect(AppleProofreading.suggestions(text, [edit("go", "goes")], rules: Self.rules).isEmpty)
        #expect(AppleProofreading.suggestions(text, [edit("She", "He")], rules: Self.rules).map(\.start) == [14])
    }

    @Test func editsStayInTheFirstCopyOfTheirSentence() {
        let text = "She go and he walk. She go and he walk."
        let sentence = "She go and he walk."
        let first = AppleProofreading.suggestions(text, [
            edit("go", "goes", sentence: sentence), edit("walk", "walks", sentence: sentence),
        ], rules: Self.rules)
        #expect(first.map(\.start) == [4, 14])
        // The same edit named twice moves on to the second copy.
        let both = AppleProofreading.suggestions(text, [
            edit("go", "goes", sentence: sentence), edit("go", "goes", sentence: sentence),
        ], rules: Self.rules)
        #expect(both.map(\.start) == [4, 24])
    }

    @Test func anEditStaysInItsPiece() {
        let text = "I has one. You has two."
        let found = AppleProofreading.suggestions(text, [edit("has", "have", in: 11..<23)], rules: Self.rules)
        #expect(found.map(\.start) == [15])
    }

    @Test func addressesAndLinksAreLeftAlone() {
        let text = "Write to sam@exmaple.com or see https://exmaple.com today."
        let found = AppleProofreading.suggestions(text, [
            edit("exmaple", "example", sentence: text), edit("exmaple", "example", sentence: text),
        ], rules: Self.rules)
        #expect(found.isEmpty)
    }

    @Test func mergedSkipsWhatClashesAndTheUsersWords() throws {
        let check = WritingCheck(rules: Self.rules)
        let text = "I could of told Kubo."
        let report = check.check(text)
        #expect(report.suggestions.map(\.label) == ["of → have"])
        let extra = AppleProofreading.suggestions(text, [edit("of", "have"), edit("Kubo", "Kobe"), edit("told", "said to")], rules: Self.rules)
        let merged = AppleProofreading.merged(report, extra, keep: ["kubo"], rules: Self.rules)
        #expect(merged.suggestions.map(\.label) == ["of → have", "told → said to"])
        #expect(merged.suggestions.first?.source == .rule)
        // Scored with what was added: one more issue, a lower score.
        let before = try #require(report.stats.score)
        let after = try #require(merged.stats.score)
        #expect(after < before)
        #expect(merged.stats.words == report.stats.words)
    }

    @Test func mergedSkipsAnEditBesideAnInsertion() {
        let text = "I want go home."
        let report = WritingCheck(rules: Self.rules).check(text, model: { _ in "I want to go home." })
        #expect(report.suggestions.contains { $0.shownReplacement == "to" })
        let extra = AppleProofreading.suggestions(text, [edit("go", "to go", sentence: text)], rules: Self.rules)
        #expect(extra.count == 1)
        let merged = AppleProofreading.merged(report, extra, keep: [], rules: Self.rules)
        #expect(!merged.suggestions.contains { $0.source == .generated })
    }

    @Test func longTextGoesToTheModelInPieces() {
        let sentence = "This sentence is about forty characters. "
        let text = String(repeating: sentence, count: 80)
        let chunks = AppleProofreading.chunks(text, limit: 400)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.0.utf16.count <= 400 })
        #expect(chunks.allSatisfy { text.utf16Slice($0.1, $0.1 + $0.0.utf16.count) == $0.0 })
    }

    @Test func aLongSentenceIsCutBetweenWords() {
        let text = String(repeating: "word and another ", count: 120) + "end"
        let chunks = AppleProofreading.chunks(text, limit: 400)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.0.utf16.count <= 400 })
        #expect(chunks.allSatisfy { text.utf16Slice($0.1, $0.1 + $0.0.utf16.count) == $0.0 })
        #expect(chunks.allSatisfy { !$0.0.hasPrefix(" ") && !$0.0.hasSuffix(" ") })
    }

    #if compiler(>=6.4)
    /// The system check itself is the simulator's to answer; whatever it finds
    /// must land on the text's own words.
    @Test @MainActor func systemGrammarLandsInsideTheText() async {
        guard #available(iOS 27, *) else { return }
        let text = "The kids plays outside and he don't know."
        for s in await AppleProofreading.systemGrammar(text, rules: Self.rules) {
            #expect(s.end <= text.utf16.count)
            #expect(text.utf16Slice(s.start, s.end) == s.original)
            #expect(s.source == .system)
        }
    }
    #endif
}
