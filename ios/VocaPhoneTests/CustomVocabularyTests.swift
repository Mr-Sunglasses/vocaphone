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
}
