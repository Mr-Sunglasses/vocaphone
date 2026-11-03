import Testing

/// Sound-alike correction: Double Metaphone, the wider budget for a spelling
/// that sounds like a term, and several words joined into one term when the
/// engine was unsure of them. Ported from VocaMac's DictionaryCorrector,
/// DoubleMetaphone and RecognitionConfidence tests; mirrored by
/// `SoundAlikeCorrectionTest.kt`.
struct SoundAlikeCorrectionTests {
    /// Ordinary words, as the shipped word list would answer for them.
    private static let dictionary: Set<String> = [
        "the", "to", "in", "it", "is", "a", "and", "ask", "about", "call", "tomorrow", "deploy", "now",
        "train", "cloud", "roll", "buy", "cooper", "pans", "pie", "torch", "for", "dessert", "then",
        "down", "open", "today", "please", "kaiser", "netties",
    ]

    private func corrected(_ text: String, _ terms: [String], unsure: Set<String>? = nil) -> String {
        VocabularyCorrection.apply(
            text, terms: terms, isDictionaryWord: Self.dictionary.contains, lowConfidenceWords: unsure
        )
    }

    // MARK: - Double Metaphone

    private func key(_ word: String) -> DoubleMetaphone.Key? {
        DoubleMetaphone.encode(word)
    }

    /// Reference values from the Apache Commons Codec implementation.
    @Test func knownKeys() {
        #expect(key("Smith") == .init(primary: "SM0", alternate: "XMT"))
        #expect(key("Schmidt") == .init(primary: "XMT", alternate: "SMT"))
        #expect(key("Thomas")?.primary == "TMS")
        #expect(key("knight")?.primary == "NT")
        #expect(key("Xavier")?.primary == "SF")
        #expect(key("Caesar")?.primary == "SSR")
        #expect(key("Philip")?.primary == "FLP")
        #expect(key("Jose")?.primary == "HS")
        #expect(key("laugh")?.primary == "LF")
    }

    @Test func soundAlikeSpellingsShareAKey() throws {
        let pairs = [
            ("kubernetes", "coopernetties"), ("kaiser", "kayzer"), ("pachauri", "pachori"),
            ("stephen", "steven"), ("catherine", "kathryn"), ("philip", "fillip"),
            ("postgresql", "postgersql"),
        ]
        for (a, b) in pairs {
            let left = try #require(key(a)), right = try #require(key(b))
            #expect(left.matches(right), "\(a) \(left) vs \(b) \(right)")
        }
    }

    @Test func differentWordsDoNotShareAKey() throws {
        for (a, b) in [("kubernetes", "cucumbers"), ("namrata", "tamrata"), ("kaiser", "kolmar")] {
            let left = try #require(key(a)), right = try #require(key(b))
            #expect(!left.matches(right), "\(a) \(left) vs \(b) \(right)")
        }
    }

    @Test func onlyEnglishLettersAreKeyed() {
        #expect(key("müller") == nil)
        #expect(key("gpt4") == nil)
        #expect(key("") == nil)
        #expect(key("aeiou")?.primary == "A")
        #expect(DoubleMetaphone.encode("Schwarzenegger", maxLength: 4)?.primary.count == 4)
    }

    @Test func soundex() {
        #expect(VocabularyCorrection.soundex("robert") == "r163")
        #expect(VocabularyCorrection.soundex("rupert") == "r163")
        #expect(VocabularyCorrection.soundex("ashcraft") == "a261")
        #expect(VocabularyCorrection.soundex("tymczak") == "t522")
        #expect(VocabularyCorrection.soundex("pfister") == "p236")
        #expect(VocabularyCorrection.soundex("gpt4") == nil)
        #expect(VocabularyCorrection.soundex("müller") == nil)
    }

    @Test func firstSound() {
        #expect(VocabularyCorrection.firstSound("cooper") == "k")
        #expect(VocabularyCorrection.firstSound("quick") == "k")
        #expect(VocabularyCorrection.firstSound("zebra") == "s")
        #expect(VocabularyCorrection.firstSound("philip") == "f")
        #expect(VocabularyCorrection.firstSound("pie") == "p")
    }

    // MARK: - A wider budget for what sounds alike

    @Test func soundingAlikeGetsOneMoreEdit() {
        #expect(corrected("call Kayzer tomorrow", ["Kaiser"]) == "call Kaiser tomorrow")
        // Two edits that do not sound alike stay put.
        #expect(corrected("call Kolmar tomorrow", ["Kaiser"]) == "call Kolmar tomorrow")
    }

    @Test func longTermsThatSoundAlikeGetTwoMoreEdits() {
        #expect(corrected("ask Pachori about it", ["Pachauri"]) == "ask Pachauri about it")
        #expect(corrected("replace it with Postgersql now", ["PostgreSQL"]) == "replace it with PostgreSQL now")
    }

    @Test func soundingAlikeStillSparesOrdinaryWords() {
        #expect(corrected("the kaiser roll", ["Kayzer"]) == "the kaiser roll")
        #expect(corrected("ask the cloud", ["Claude"], unsure: ["cloud"]) == "ask the cloud")
    }

    @Test func aDifferentFirstLetterNeedsTheSameSound() {
        // c and k are one sound, and the words sound alike.
        #expect(corrected("ask Casper now", ["Kasper"]) == "ask Kasper now")
        // Same first sound, but not alike: a different first letter stays.
        // The comma keeps "now" out of a join, so this is the first-letter rule.
        #expect(corrected("ask Kolmarz, now", ["Calmerson"]) == "ask Kolmarz, now")
        #expect(corrected("ask Tamrata about it", ["Namrata"]) == "ask Tamrata about it")
    }

    // MARK: - Several words heard for one

    @Test func realWordsThatSoundLikeATermJoinOnlyWhenTheEngineWasUnsure() {
        #expect(corrected("deploy to cooper netties now", ["Kubernetes"], unsure: ["netties"])
            == "deploy to Kubernetes now")
        #expect(corrected("train it in pie torch", ["PyTorch"], unsure: ["pie", "torch"]) == "train it in PyTorch")
        // Sure of the words, or no confidence reported: left as heard.
        #expect(corrected("deploy to cooper netties now", ["Kubernetes"], unsure: [])
            == "deploy to cooper netties now")
        #expect(corrected("deploy to cooper netties now", ["Kubernetes"]) == "deploy to cooper netties now")
    }

    /// From an engine that reports nothing, a word off the list is the
    /// only evidence there is.
    @Test func anUnknownWordInTheRunIsEvidenceEnough() {
        #expect(corrected("deploy to cooper netteez now", ["Kubernetes"]) == "deploy to Kubernetes now")
    }

    /// From an engine that reports confidence, only its doubt counts: a word
    /// off the list, such as a name, is not evidence it misheard.
    @Test func anEngineThatReportsConfidenceMustHaveDoubtedAWord() {
        let text = "he said Ruth, a little dubiously"
        func joined(_ unsure: Set<String>?) -> String {
            VocabularyCorrection.apply(
                text, terms: ["Siddharth"],
                isDictionaryWord: { ["he", "said", "a", "little", "dubiously"].contains($0) },
                lowConfidenceWords: unsure
            )
        }
        #expect(joined([]) == text)
        #expect(joined(["little"]) == text)
        #expect(joined(nil) == "he Siddharth, a little dubiously")
        #expect(corrected("deploy to cooper netteez now", ["Kubernetes"], unsure: [])
            == "deploy to cooper netteez now")
        #expect(corrected("deploy to cooper netteez now", ["Kubernetes"], unsure: ["netteez"])
            == "deploy to Kubernetes now")
    }

    @Test func soundAlikeJoinNeedsTheWholeKey() {
        #expect(corrected("buy cooper pans now", ["Kubernetes"], unsure: ["cooper", "pans"]) == "buy cooper pans now")
    }

    /// A term that is itself an ordinary word could be any run of words that
    /// sounds like it.
    @Test func aTermThatIsAnOrdinaryWordIsNeverJoined() {
        let text = "deploy to cooper netteez now"
        #expect(VocabularyCorrection.apply(
            text, terms: ["Kubernetes"], isDictionaryWord: { Self.dictionary.contains($0) || $0 == "kubernetes" }
        ) == text)
    }

    /// One unsure "pie" must not let a confidently heard "pie torch"
    /// elsewhere become PyTorch.
    @Test func aWordHeardOnceSureIsNeverUnsure() {
        var confidence = RecognitionConfidence()
        for (word, probability) in [
            (" pie", 0.31), (" for", 0.98), (" dessert", 0.97), (" then", 0.99), (" pie", 0.96), (" torch", 0.95),
        ] {
            confidence.add(word, probability: probability)
        }
        #expect(confidence.lowConfidenceWords == [])
        #expect(corrected("pie for dessert then pie torch", ["PyTorch"], unsure: confidence.lowConfidenceWords)
            == "pie for dessert then pie torch")
    }

    @Test func soundAlikeIsEnglishOnly() {
        let text = "deploy to cooper netteez now"
        #expect(VocabularyCorrection.apply(text, terms: ["Kubernetes"], nearMisses: false) == text)
    }

    @Test func snippetTriggersAreNeverJoined() {
        let text = "deploy to cooper netteez now"
        let trigger = text.range(of: "netteez")!
        #expect(VocabularyCorrection.apply(
            text, terms: ["Kubernetes"], isDictionaryWord: Self.dictionary.contains, protectedRanges: [trigger]
        ) == text)
    }

    // MARK: - Confidence

    @Test func noConfidenceMeansNil() {
        var confidence = RecognitionConfidence()
        confidence.add("hello", probability: nil)
        #expect(confidence.lowConfidenceWords == nil)
        #expect(RecognitionConfidence.unreported.lowConfidenceWords == nil)
    }

    @Test func collectsUnsureWordsNormalized() {
        var confidence = RecognitionConfidence()
        for (word, probability) in [(" Deploy", 0.97), (" to", 0.99), (" cooper", 0.41), (" netties,", 0.32)] {
            confidence.add(word, probability: probability)
        }
        #expect(confidence.lowConfidenceWords == ["cooper", "netties"])
    }

    @Test func sureOfEverythingIsAnEmptySet() {
        var confidence = RecognitionConfidence()
        confidence.add("yes", probability: 0.95)
        #expect(confidence.lowConfidenceWords == [])
    }

    @Test func wordsAreBuiltFromTokens() {
        let tokens: [RecognitionConfidence.Token] = [
            .init(text: " deploy", logProbability: -0.01),
            .init(text: " cooper", logProbability: -0.05),
            .init(text: " net", logProbability: -0.2),
            .init(text: "ties", logProbability: -2.0),
            .init(text: ",", logProbability: -0.01),
        ]
        // exp(-2) is 0.14: the minimum calls "netties" unsure; the geometric
        // mean of -0.2, -2.0 and -0.01 is exp(-0.74) = 0.48, unsure too.
        #expect(RecognitionConfidence(tokens: tokens, score: .minimum).lowConfidenceWords == ["netties"])
        #expect(RecognitionConfidence(tokens: tokens, score: .geometricMean).lowConfidenceWords == ["netties"])
        let mild = [RecognitionConfidence.Token(text: " ok", logProbability: -0.3)]
        #expect(RecognitionConfidence(tokens: mild, score: .geometricMean).lowConfidenceWords == [])
    }

    @Test func sentencePieceMarksStartWords() {
        let confidence = RecognitionConfidence(
            tokenLines: "-0.0100\t\u{2581}pie\n-1.5000\t\u{2581}tor\n-0.1000\tch\nnot a line\n",
            score: .minimum
        )
        #expect(confidence.lowConfidenceWords == ["torch"])
    }

    @Test func hyphenatedWordsAreTheWordsCorrectionSees() {
        var confidence = RecognitionConfidence()
        confidence.add(" pie-tot", probability: 0.2)
        #expect(confidence.lowConfidenceWords == ["pie", "tot"])
    }

    @Test func mergingKeepsTheRule() {
        var first = RecognitionConfidence()
        first.add("pie", probability: 0.2)
        var second = RecognitionConfidence()
        second.add("pie", probability: 0.9)
        second.add("torch", probability: 0.3)
        #expect(first.merging(second).lowConfidenceWords == ["torch"])
        #expect(RecognitionConfidence.unreported.merging(.unreported).lowConfidenceWords == nil)
        #expect(RecognitionConfidence.unreported.merging(first).lowConfidenceWords == ["pie"])
    }

    @Test func sherpaTranscriptsMergeTheirConfidence() {
        var unsure = RecognitionConfidence()
        unsure.add("netties", probability: 0.2)
        let left = SherpaTranscript(text: "deploy to cooper")
        let right = SherpaTranscript(text: "netties now", confidence: unsure)
        let merged = left.appending(right, deduplicateOverlap: false)
        #expect(merged.confidence.lowConfidenceWords == ["netties"])
        #expect(merged.trimmed.confidence == merged.confidence)
    }
}
