import Foundation
import Testing

/// Where Apple's checkers' edits land in the Writing check screen: only on
/// words that are in the text, only small changes, never over something
/// already found or the user's own words.
struct AppleProofreadingTests {
    private static let rules = WritingCheckTests.rules

    private func edit(_ original: String, _ replacement: String, _ reason: String = "Why.") -> (AppleProofreading.Edit, Int) {
        (AppleProofreading.Edit(original: original, replacement: replacement, reason: reason), 0)
    }

    @Test func generatedEditsLandOnTheirWordsInOrder() {
        let text = "She go to the store and she go home."
        let found = AppleProofreading.suggestions(text, [edit("go", "goes"), edit("go", "goes")], rules: Self.rules)
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

    @Test func mergedSkipsWhatClashesAndTheUsersWords() {
        let check = WritingCheck(rules: Self.rules)
        let text = "I could of told Kubo."
        let report = check.check(text)
        #expect(report.suggestions.map(\.label) == ["of → have"])
        let extra = AppleProofreading.suggestions(text, [edit("of", "have"), edit("Kubo", "Kobe"), edit("told", "said to")], rules: Self.rules)
        let merged = AppleProofreading.merged(report, extra, keep: ["kubo"])
        #expect(merged.suggestions.map(\.label) == ["of → have", "told → said to"])
        #expect(merged.suggestions.first?.source == .rule)
    }

    @Test func longTextGoesToTheModelInPieces() {
        let sentence = "This sentence is about forty characters. "
        let text = String(repeating: sentence, count: 80)
        let chunks = AppleProofreading.chunks(text, limit: 400)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.0.utf16.count <= 400 })
        #expect(chunks.allSatisfy { text.utf16Slice($0.1, $0.1 + $0.0.utf16.count) == $0.0 })
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
