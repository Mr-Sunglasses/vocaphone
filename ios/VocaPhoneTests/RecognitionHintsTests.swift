import Testing

/// Matches the Android client's `RecognitionHintsTest`: both build the same
/// list and the same engine strings from the same stored vocabulary.
struct RecognitionHintsTests {
    // MARK: - The list

    @Test func theUsersFirstTermEndsTheList() {
        #expect(
            RecognitionHints.terms(vocabulary: ["Kanishk", "VocaHQ", "Tailscale"])
                == ["Tailscale", "VocaHQ", "Kanishk"]
        )
        #expect(RecognitionHints.terms(vocabulary: []).isEmpty)
    }

    @Test func contextComesFirstThenReplacementsThenTheUsersOwnWords() {
        let terms = RecognitionHints.terms(
            vocabulary: ["Kanishk", "Namrata"],
            replacementTargets: ["GitHub", "Grafana"],
            contextTerms: ["Kubernetes", "Redis"]
        )
        #expect(terms == ["Redis", "Kubernetes", "Grafana", "GitHub", "Namrata", "Kanishk"])
    }

    @Test func theUsersSpellingWinsADuplicate() {
        let terms = RecognitionHints.terms(
            vocabulary: ["GitHub"],
            replacementTargets: ["github", "Figma"],
            contextTerms: ["GITHUB", "figma", "Jira"]
        )
        #expect(terms == ["Jira", "Figma", "GitHub"])
    }

    @Test func aReplacementThatTypesASnippetIsNoHint() {
        #expect(RecognitionHints.isHintableReplacement("GitHub"))
        #expect(RecognitionHints.isHintableReplacement("Claude Code"))
        #expect(!RecognitionHints.isHintableReplacement("me@example.com"))
        #expect(!RecognitionHints.isHintableReplacement("https://vocahq.com"))
        #expect(!RecognitionHints.isHintableReplacement("see you at the usual place"))
        #expect(!RecognitionHints.isHintableReplacement("42"))
        #expect(!RecognitionHints.isHintableReplacement("x"))
    }

    @Test func contextTermsStopAtTheirCountAndTheCharacterBudget() {
        let many = (1...300).map { "Context\($0)" }
        let counted = RecognitionHints.terms(vocabulary: ["Kanishk"], contextTerms: many)
        #expect(counted.count == RecognitionHints.maximumContextTerms + 1)
        // The best-ranked context terms are kept, and sit right before the user's.
        #expect(counted.suffix(2) == ["Context1", "Kanishk"])

        let long = (1...300).map { "Context\($0)" + String(repeating: "x", count: 30) }
        let budgeted = RecognitionHints.terms(vocabulary: ["Kanishk"], contextTerms: long)
        #expect(budgeted.joined(separator: ", ").count <= RecognitionHints.maximumCharacters)
        #expect(budgeted.last == "Kanishk")
    }

    @Test func theUsersOwnWordsAreNeverCutByTheListBudget() {
        let vocabulary = (1...200).map { "Colleague\($0)" + String(repeating: "y", count: 20) }
        let terms = RecognitionHints.terms(vocabulary: vocabulary, contextTerms: ["Screen"])
        #expect(terms.count == 200)
        #expect(!terms.contains("Screen"))
    }

    // MARK: - Whisper

    @Test func theWhisperPromptIsTheListAsText() {
        #expect(
            RecognitionHints.whisperPrompt(["Tailscale", "VocaHQ", "Kanishk"])
                == "Kanishk, VocaHQ, Tailscale."
        )
        #expect(RecognitionHints.whisperPrompt([]) == "")
    }

    @Test func anOverLongPromptLosesTheFrontOfTheListAndNeverHalfATerm() {
        let terms = RecognitionHints.terms(
            vocabulary: (1...200).map { "Supercalifragilistic\($0)" }
        )
        let prompt = RecognitionHints.whisperPrompt(terms)
        #expect(prompt.count <= RecognitionHints.whisperPromptCharacters)
        // The user's first terms survive, written in the user's order.
        #expect(prompt.hasPrefix("Supercalifragilistic1, Supercalifragilistic2, "))
        for term in prompt.dropLast().components(separatedBy: ", ") {
            #expect(term.hasPrefix("Supercalifragilistic"))
            #expect(Int(term.dropFirst("Supercalifragilistic".count)) != nil)
        }
    }

    /// A stand-in tokenizer: one token for every three characters, which is
    /// about what Whisper's makes of names.
    private static func roughTokens(_ text: String) -> Int { (text.count + 2) / 3 }

    @Test func theWhisperKitPromptStopsAtItsTokenBudgetKeepingTheFirstTerms() {
        let terms = RecognitionHints.terms(vocabulary: (1...40).map { "Colleague\($0)" })
        let prompt = RecognitionHints.whisperPrompt(
            terms, maximumTokens: RecognitionHints.whisperKitPromptTokens, tokenCount: Self.roughTokens
        )
        #expect(Self.roughTokens(prompt) <= RecognitionHints.whisperKitPromptTokens)
        #expect(prompt.hasPrefix("Colleague1, Colleague2, "))
        #expect(!prompt.contains("Colleague40"))
    }

    @Test func contextIsTheFirstToGoFromAFullPrompt() {
        let terms = RecognitionHints.terms(
            vocabulary: ["Kanishk", "Namrata"],
            contextTerms: (1...30).map { "Screen\($0)" }
        )
        let prompt = RecognitionHints.whisperPrompt(terms, maximumTokens: 20, tokenCount: Self.roughTokens)
        #expect(prompt.hasPrefix("Kanishk, Namrata, Screen1, "))
        #expect(!prompt.contains("Screen30"))
    }

    @Test func aTermThatAloneExceedsTheBudgetLeavesNoPrompt() {
        #expect(RecognitionHints.whisperPrompt(
            [String(repeating: "x", count: 60)], maximumTokens: 4, tokenCount: Self.roughTokens
        ) == "")
    }

    @Test func aPastedListOfThousandsOnlyTokenizesWhatFits() {
        let terms = RecognitionHints.terms(vocabulary: (1...50_000).map { "Name\($0)" })
        var tokenized = 0
        let prompt = RecognitionHints.whisperPrompt(
            terms, maximumTokens: RecognitionHints.whisperKitPromptTokens,
            tokenCount: { tokenized += 1; return Self.roughTokens($0) }
        )
        #expect(prompt.hasPrefix("Name1, Name2, "))
        #expect(Self.roughTokens(prompt) <= RecognitionHints.whisperKitPromptTokens)
        // At most one tokenization per term that fits in the character budget.
        #expect(tokenized <= RecognitionHints.whisperPromptCharacters / 3)
    }

    @Test func storedVocabularyReachesThePromptInTheUsersPriority() {
        let terms = RecognitionHints.terms(vocabulary: CustomVocabulary.terms("Kanishk\nVocaHQ, Tailscale"))
        #expect(RecognitionHints.whisperPrompt(terms) == "Kanishk, VocaHQ, Tailscale.")
    }

    // MARK: - Qwen3-ASR

    @Test func qwen3HotwordsAreCommaSeparatedWithNoSpaces() {
        #expect(
            RecognitionHints.qwen3Hotwords(["Tailscale", "Claude Code", "Kanishk"])
                == "Kanishk,Claude Code,Tailscale"
        )
        #expect(RecognitionHints.qwen3Hotwords([]) == nil)
        #expect(RecognitionHints.qwen3Hotwords(["  ", ","]) == nil)
    }

    @Test func aCommaInsideATermWouldSplitIt() {
        #expect(RecognitionHints.qwen3Hotwords(["Smith, Jones"]) == "Smith  Jones")
    }

    @Test func qwen3KeepsTheEndOfTheListWithinItsCaps() {
        let terms = RecognitionHints.terms(vocabulary: (1...50).map { "Name\($0)" })
        let hotwords = RecognitionHints.qwen3Hotwords(terms) ?? ""
        let kept = hotwords.components(separatedBy: ",")
        #expect(kept.count == RecognitionHints.maximumHotwords)
        #expect(kept.first == "Name1")
        #expect(!kept.contains("Name21"))

        let long = RecognitionHints.qwen3Hotwords((1...10).map { "Term\($0)" + String(repeating: "z", count: 40) }) ?? ""
        #expect(long.count <= RecognitionHints.maximumHotwordCharacters)
        #expect(long.hasPrefix("Term10" + String(repeating: "z", count: 40) + ","))
    }

    @Test func onlyQwen3TakesHotwords() {
        let terms = ["Kanishk"]
        #expect(RecognitionHints.sherpaHotwords(family: .qwen3Asr, terms: terms) == "Kanishk")
        for family in [SherpaFamily.nemoTransducer, .nemoCtc, .canary, .senseVoice, .zipformerTransducer] {
            #expect(RecognitionHints.sherpaHotwords(family: family, terms: terms) == nil)
        }
        #expect(RecognitionHints.sherpaHotwords(family: nil, terms: terms) == nil)
        #expect(RecognitionHints.sherpaHotwords(family: .qwen3Asr, terms: []) == nil)
    }

    @Test func whisperAndQwen3AreTheModelsAVocabularyReachesWhileDecoding() throws {
        let qwen = try #require(LocalModelCatalog.descriptor(for: "qwen3-asr-0.6b"))
        let parakeet = try #require(LocalModelCatalog.descriptor(for: "parakeet-tdt-0.6b-v2-en"))
        let whisper = try #require(LocalModelCatalog.descriptor(for: "openai_whisper-small_216MB"))
        #expect(qwen.supportsCustomVocabulary)
        #expect(whisper.supportsCustomVocabulary)
        #expect(!parakeet.supportsCustomVocabulary)
    }
}
