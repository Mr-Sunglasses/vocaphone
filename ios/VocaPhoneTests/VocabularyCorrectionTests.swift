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

    /// A snippet trigger expands after correction runs, so correction must not
    /// rewrite it into a term first.
    @Test func snippetTriggersAreLeftForTheSnippet() {
        let transcript = "sign it kanish please"
        let text = VocabularyCorrection.apply(
            transcript,
            terms: ["Kanishk"],
            protectedRanges: SnippetExpander.triggerRanges(
                in: transcript,
                using: [Snippet(trigger: "kanish", expansion: "Kanishk Pachauri")]
            )
        )
        #expect(text == transcript)
        let finished = DictatedTranscript.finished(
            "sign it kanish",
            style: .casual,
            repairSpeech: false,
            numbersAsDigits: false,
            spokenEmoji: false,
            snippets: [Snippet(trigger: "kanish", expansion: "Kanishk Pachauri")],
            vocabulary: ["Kanishk"]
        )
        #expect(finished.contains("Kanishk Pachauri"))
    }

    /// The term's own punctuation may join its words; other punctuation may not.
    @Test func aTermsOwnPunctuationJoinsItsWords() {
        #expect(corrected("ask o'brien now", ["O'Brien"]) == "ask O'Brien now")
        #expect(corrected("a wi-fi network", ["Wi-Fi"]) == "a Wi-Fi network")
        #expect(corrected("o, brien", ["O'Brien"]) == "o, brien")
    }

    /// Only what the expander will actually expand is protected: "o brien"
    /// as a trigger does not match "o'brien", so the term still applies.
    @Test func aTriggerTheExpanderWouldNotMatchProtectsNothing() {
        let transcript = "ask o'brien now"
        let ranges = SnippetExpander.triggerRanges(
            in: transcript,
            using: [Snippet(trigger: "o brien", expansion: "Mr O'Brien")]
        )
        #expect(ranges.isEmpty)
        #expect(VocabularyCorrection.apply(transcript, terms: ["O'Brien"], protectedRanges: ranges)
            == "ask O'Brien now")
    }

    /// Every term counts however long the list, the last one included: an
    /// exact match is a lookup and is never rationed. One-letter slips are
    /// found within a fixed budget, which a realistic list never exhausts.
    @Test func aHugeListStillAppliesEveryTerm() {
        let many = (0..<5_000).map { "Term\($0)x" }
        #expect(VocabularyCorrection.apply("kanish", terms: many + ["Kanishk"]) == "Kanishk")
        let transcript = Array(repeating: "please tell whisper kit about the plan", count: 200)
            .joined(separator: " ")
        let corrected = VocabularyCorrection.apply(transcript, terms: many + ["WhisperKit"])
        #expect(corrected.components(separatedBy: "WhisperKit").count == 201)
    }
}
