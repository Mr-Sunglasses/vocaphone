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
}
