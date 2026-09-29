import Testing

/// Matches the Android client's `CustomVocabularyTest`: the stored text is
/// shared between the two, so it has to parse the same way on both.
struct CustomVocabularyTests {
    @Test func termsSplitOnNewlinesAndCommasButNeverInsideAPhrase() {
        #expect(
            CustomVocabulary.terms("Claude Code\nTailscale, VocaPhone")
                == ["Claude Code", "Tailscale", "VocaPhone"]
        )
    }

    @Test func theFirstSpellingOfADuplicateIsTheOneKept() {
        #expect(CustomVocabulary.terms("VocaPhone, vocaphone, VOCAPHONE") == ["VocaPhone"])
    }

    @Test func blankEntriesAndStraySeparatorsAreDropped() {
        #expect(CustomVocabulary.terms(nil).isEmpty)
        #expect(CustomVocabulary.terms("  \n , , \n ").isEmpty)
        #expect(CustomVocabulary.terms(",\n Kanishk ,\n") == ["Kanishk"])
    }

    @Test func thePromptIsACommaSeparatedListTheDecoderCanReadAsText() {
        #expect(
            CustomVocabulary.whisperPrompt("Kanishk\nVocaHQ\nTailscale")
                == "Kanishk, VocaHQ, Tailscale."
        )
        #expect(CustomVocabulary.whisperPrompt("") == "")
    }

    @Test func anOverLongListIsTruncatedAtATermBoundary() {
        let prompt = CustomVocabulary.whisperPrompt(
            (1...200).map { "Supercalifragilistic\($0)" }.joined(separator: "\n")
        )
        #expect(prompt.count <= 641)
        // Never a half-written term: every entry present is complete.
        for term in prompt.dropLast().components(separatedBy: ", ") {
            #expect(term.hasPrefix("Supercalifragilistic"))
            #expect(Int(term.dropFirst("Supercalifragilistic".count)) != nil)
        }
    }

    /// A stand-in tokenizer: one token for every three characters, which is
    /// about what Whisper's makes of names.
    private static func roughTokens(_ text: String) -> Int { (text.count + 2) / 3 }

    @Test func theWhisperKitPromptStopsAtItsTokenBudgetKeepingTheFirstTerms() {
        let list = (1...40).map { "Colleague\($0)" }.joined(separator: "\n")
        let prompt = CustomVocabulary.whisperPrompt(list, maximumTokens: 48, tokenCount: Self.roughTokens)

        #expect(Self.roughTokens(prompt) <= 48)
        // The front of the list survives; WhisperKit's own cut kept the back.
        #expect(prompt.hasPrefix("Colleague1, Colleague2, "))
        #expect(!prompt.contains("Colleague40"))
        for term in prompt.dropLast().components(separatedBy: ", ") {
            #expect(term.hasPrefix("Colleague") && Int(term.dropFirst("Colleague".count)) != nil)
        }
    }

    @Test func aTermThatAloneExceedsTheBudgetLeavesNoPrompt() {
        #expect(CustomVocabulary.whisperPrompt(
            String(repeating: "x", count: 60), maximumTokens: 4, tokenCount: Self.roughTokens
        ) == "")
    }

    @Test func noBudgetIsTheCharacterLimitAlone() {
        let list = "Kanishk\nVocaHQ\nTailscale"
        #expect(CustomVocabulary.whisperPrompt(list, maximumTokens: nil) { _ in .max }
            == CustomVocabulary.whisperPrompt(list))
    }
}
