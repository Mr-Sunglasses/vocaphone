import Testing

/// The user's vocabulary, applied to a finished transcript from any model.
struct VocabularyCorrectionTests {
    private static let dictionary: Set<String> = ["strip", "vocal", "phone", "must", "whisper", "kit", "is", "here"]

    private func corrected(_ text: String, _ terms: [String]) -> String {
        VocabularyCorrection.apply(text, terms: terms, isDictionaryWord: Self.dictionary.contains)
    }

    @Test func spacingAndCaseAreFixed() {
        #expect(corrected("I use whisper kit daily.", ["WhisperKit"]) == "I use WhisperKit daily.")
        #expect(corrected("Open vocaphone now", ["VocaPhone"]) == "Open VocaPhone now")
        #expect(corrected("Open Voca Phone now", ["VocaPhone"]) == "Open VocaPhone now")
    }

    @Test func oneLetterOutIsFixed() {
        #expect(corrected("Kanish is here.", ["Kanishk"]) == "Kanishk is here.")
        #expect(corrected("Try vocal phone.", ["VocaPhone"]) == "Try VocaPhone.")
    }

    /// A possessive keeps its apostrophe and the words around keep their
    /// punctuation.
    @Test func punctuationStaysPut() {
        #expect(corrected("Kanish's laptop, then Kanish.", ["Kanishk"]) == "Kanishk's laptop, then Kanishk.")
        #expect(corrected("(whisper kit)", ["WhisperKit"]) == "(WhisperKit)")
    }

    /// An ordinary word is what the user said unless it is exactly the term.
    @Test func dictionaryWordsAreLeftAlone() {
        #expect(corrected("Strip the wire.", ["Stripe"]) == "Strip the wire.")
        #expect(corrected("You must go.", ["Rust"]) == "You must go.")
    }

    @Test func shortTermsAreNeverFuzzy() {
        #expect(corrected("The cat sat.", ["Cats"]) == "The cat sat.")
        #expect(corrected("Use rust here", ["Rust"]) == "Use Rust here")
    }

    /// Two phrases with a comma between them are not one term.
    @Test func aTermDoesNotCrossPunctuation() {
        #expect(corrected("vocal, phone", ["VocaPhone"]) == "vocal, phone")
    }

    /// A term already spelled right is not swallowed with the word after it.
    @Test func aCorrectTermIsLeftAsItIs() {
        #expect(corrected("VocaPhone s app", ["VocaPhone"]) == "VocaPhone s app")
        #expect(corrected("VocaPhone rocks", ["VocaPhone"]) == "VocaPhone rocks")
    }

    @Test func differentFirstLettersAreDifferentWords() {
        #expect(corrected("Fanishk called", ["Kanishk"]) == "Fanishk called")
    }

    @Test func multiWordTermsMatchAcrossTheirWords() {
        #expect(corrected("ask claude code about it", ["Claude Code"]) == "ask Claude Code about it")
    }

    @Test func nothingToDo() {
        #expect(corrected("", ["VocaPhone"]) == "")
        #expect(corrected("Hello there.", []) == "Hello there.")
    }

    @Test func boundedDistance() {
        #expect(VocabularyCorrection.distance("kanish", "kanishk", limit: 2) == 1)
        #expect(VocabularyCorrection.distance("abc", "xyz", limit: 1) == 2)
    }

    /// Wired into the funnel every route goes through, and kept out of Raw.
    @Test func theFunnelAppliesItExceptForRaw() {
        let casual = DictatedTranscript.finished(
            "send it to kanish",
            style: .casual,
            repairSpeech: false,
            numbersAsDigits: false,
            spokenEmoji: false,
            snippets: [],
            vocabulary: ["Kanishk"]
        )
        #expect(casual.contains("Kanishk"))
        let raw = DictatedTranscript.finished(
            "send it to kanish",
            style: .raw,
            repairSpeech: false,
            numbersAsDigits: false,
            spokenEmoji: false,
            snippets: [],
            vocabulary: ["Kanishk"]
        )
        #expect(!raw.contains("Kanishk"))
    }
}
