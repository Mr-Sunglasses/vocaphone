import Foundation
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

    // MARK: - Transducers

    @Test func transducerHotwordsAreSlashSeparatedMostImportantFirst() {
        let terms = RecognitionHints.terms(vocabulary: ["Kanishk", "Claude Code", "Tailscale"])
        #expect(RecognitionHints.transducerHotwords(terms) == "Kanishk/Claude Code/Tailscale")
        #expect(RecognitionHints.transducerHotwords([]) == nil)
        #expect(RecognitionHints.transducerHotwords(["  ", "/", ":#@"]) == nil)
    }

    @Test func transducerHotwordsDropWhatSherpaWouldParseAsSyntax() {
        // "/" separates phrases, a leading ":" is a score, and "#" and "@"
        // start a threshold and a label; a tab or a newline would split the
        // phrase list itself.
        #expect(RecognitionHints.transducerHotwords(["TCP/IP"]) == "TCP IP")
        #expect(RecognitionHints.transducerHotwords([":Kanishk:2.0"]) == "Kanishk 2.0")
        #expect(RecognitionHints.transducerHotwords(["C#", "a@b.com"]) == "a b.com/C")
        #expect(RecognitionHints.transducerHotwords(["Claude\tCode\nCLI"]) == "Claude Code CLI")
    }

    @Test func transducerHotwordsKeepTheEndOfTheListWithinTheirCap() {
        let terms = RecognitionHints.terms(vocabulary: (1...100).map { "Name\($0)" })
        let kept = (RecognitionHints.transducerHotwords(terms) ?? "").components(separatedBy: "/")
        #expect(kept.count == RecognitionHints.maximumTransducerHotwords)
        #expect(kept.first == "Name1")
        #expect(kept.last == "Name\(RecognitionHints.maximumTransducerHotwords)")
    }

    @Test func eachModelTakesItsOwnHotwords() throws {
        let terms = RecognitionHints.terms(vocabulary: ["Kanishk", "Tailscale"])
        let qwen = try #require(LocalModelCatalog.descriptor(for: "qwen3-asr-0.6b"))
        let unified = try #require(LocalModelCatalog.descriptor(for: "parakeet-unified-0.6b-en"))
        #expect(RecognitionHints.sherpaHotwords(for: qwen, terms: terms) == "Kanishk,Tailscale")
        #expect(RecognitionHints.sherpaHotwords(for: unified, terms: terms) == "Kanishk/Tailscale")
        #expect(RecognitionHints.sherpaHotwords(for: unified, terms: []) == nil)
        let others = LocalModelCatalog.all.filter {
            $0.engine == .sherpaOnnx && $0.id != qwen.id && $0.id != unified.id
        }
        #expect(others.count > 5)
        for model in others {
            #expect(RecognitionHints.sherpaHotwords(for: model, terms: terms) == nil, "\(model.id)")
        }
    }

    @Test func whisperQwen3AndUnifiedAreTheModelsAVocabularyReachesWhileDecoding() throws {
        let reached = Set(LocalModelCatalog.all.filter(\.supportsCustomVocabulary).map(\.id))
        let whisper = Set(LocalModelCatalog.all.filter { $0.engine == .whisperKit }.map(\.id))
        #expect(reached == whisper.union(["qwen3-asr-0.6b", "parakeet-unified-0.6b-en"]))
    }

    // MARK: - Transducer search

    @Test func onlyParakeetUnifiedHasAHotwordVocabulary() {
        let models = LocalModelCatalog.all.filter { $0.hotwordVocabularyFile != nil }
        #expect(models.map(\.id) == ["parakeet-unified-0.6b-en"])
        #expect(models.first?.hotwordVocabularyFile == "parakeet-unified-0.6b-en.bpe.vocab")
        // The TDT Parakeets drop sentences in beam search on the pinned runtime.
        for id in ["parakeet-tdt-0.6b-v2-en", "parakeet-tdt-0.6b-v3"] {
            #expect(LocalModelCatalog.descriptor(for: id)?.hotwordVocabularyFile == nil, "\(id)")
        }
    }

    @Test func theBundledVocabularyIsWhereTheProjectBundlesIt() throws {
        let unified = try #require(LocalModelCatalog.descriptor(for: "parakeet-unified-0.6b-en"))
        let name = try #require(unified.hotwordVocabularyFile)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vocabulary = try String(contentsOf: root.appendingPathComponent("assets/speech/\(name)"), encoding: .utf8)
        let lines = vocabulary.split(separator: "\n")
        #expect(lines.count == 1_024)
        #expect(lines.first == "<unk>\t0.0")
        let project = try String(contentsOf: root.appendingPathComponent("ios/project.yml"), encoding: .utf8)
        #expect(project.contains("../assets/speech/\(name)"))
    }

    @Test func aVocabularyTurnsTheTransducerToBeamSearchWithHotwords() {
        for quality in TranscriptionQuality.allCases {
            let beam = SherpaSearch(family: .nemoTransducer, quality: quality, vocabulary: "/x/u.bpe.vocab")
            #expect(beam.decodingMethod == "modified_beam_search")
            #expect(beam.maxActivePaths == RecognitionHints.transducerBeamWidth)
            #expect(beam.bpeVocabulary == "/x/u.bpe.vocab")
            #expect(beam.hotwordScore == RecognitionHints.transducerHotwordScore)
            #expect(beam.takesHotwords)

            for vocabulary in [nil, ""] as [String?] {
                let greedy = SherpaSearch(family: .nemoTransducer, quality: quality, vocabulary: vocabulary)
                #expect(greedy.decodingMethod == "greedy_search")
                #expect(!greedy.takesHotwords)
            }
        }
    }

    @Test func noOtherFamilyEverGetsBeamSearchFromAVocabulary() {
        let families: [SherpaFamily] = [
            .senseVoice, .moonshine, .dolphinCtc, .canary, .nemoCtc, .paraformer,
            .moonshineV2, .omnilingualCtc, .zipformerTransducer, .qwen3Asr
        ]
        for family in families {
            for quality in TranscriptionQuality.allCases {
                let search = SherpaSearch(family: family, quality: quality, vocabulary: "/x/u.bpe.vocab")
                #expect(search.decodingMethod == "greedy_search", "\(family)")
                #expect(!search.takesHotwords, "\(family)")
            }
        }
    }

    // MARK: - Stopped early

    /// A tone at speech level for `seconds`, then `silence` seconds of nothing.
    private func audio(speech seconds: Double, silence: Double = 0) -> [Float] {
        let rate = Double(SherpaLongAudio.sampleRate)
        let voiced = (0..<Int(seconds * rate)).map { Float(0.1 * sin(Double($0) * 0.07)) }
        return voiced + [Float](repeating: 0, count: Int(silence * rate))
    }

    @Test func speechAfterTheLastTokenIsAStopTooEarly() {
        let samples = audio(speech: 8)
        #expect(SherpaHotwordCheck.stoppedEarly(samples, lastTokenSeconds: 3))
        #expect(SherpaHotwordCheck.stoppedEarly(samples, lastTokenSeconds: nil))
    }

    @Test func aTranscriptThatRunsToTheEndOfTheSpeechIsNot() {
        #expect(!SherpaHotwordCheck.stoppedEarly(audio(speech: 8), lastTokenSeconds: 7.8))
        // The usual end of a dictation: the last word, then a pause.
        #expect(!SherpaHotwordCheck.stoppedEarly(audio(speech: 4, silence: 4), lastTokenSeconds: 3.8))
        // Silence alone never asks for another decode.
        #expect(!SherpaHotwordCheck.stoppedEarly(audio(speech: 0, silence: 5), lastTokenSeconds: nil))
    }

    @Test func aTailShorterThanTheMinimumIsNotJudged() {
        let total = 6.0
        let last = total - SherpaHotwordCheck.marginSeconds - SherpaHotwordCheck.minimumTailSeconds + 0.2
        #expect(!SherpaHotwordCheck.stoppedEarly(audio(speech: total), lastTokenSeconds: last))
    }

    @Test func aHotwordSaidTwiceInARowIsALoop() {
        let hotwords = "Aoife/Slack/Jetpack Compose"
        #expect(SherpaHotwordCheck.repeatsAHotword("tell Aoife on Slack Slack Slack", hotwords: hotwords))
        #expect(SherpaHotwordCheck.repeatsAHotword("Jetpack Compose, Jetpack Compose.", hotwords: hotwords))
        #expect(!SherpaHotwordCheck.repeatsAHotword("tell Aoife on Slack", hotwords: hotwords))
        #expect(!SherpaHotwordCheck.repeatsAHotword("Slack it on Slack", hotwords: hotwords))
        // Only the user's words: an ordinary repeat is the speaker's.
        #expect(!SherpaHotwordCheck.repeatsAHotword("very very good", hotwords: hotwords))
        #expect(!SherpaHotwordCheck.repeatsAHotword("", hotwords: hotwords))
    }

    @Test func aRepeatIsFoundWhateverItsCase() {
        #expect(SherpaHotwordCheck.repeatsAHotword("on Slack Slack", hotwords: "slack"))
        #expect(SherpaHotwordCheck.repeatsAHotword("on Slack slack", hotwords: "Slack"))
        #expect(SherpaHotwordCheck.repeatsAHotword("JETPACK compose Jetpack Compose", hotwords: "Jetpack Compose"))
        #expect(!SherpaHotwordCheck.repeatsAHotword("on Slack", hotwords: "slack"))
    }

    @Test func theTunedSearchStaysBelowTheRunawayScore() {
        // Score 4 with a beam of 4 repeated hotwords into ordinary speech
        // ("Jira Jira Jira") on vocab-en; see docs/local-model-review.md.
        #expect(RecognitionHints.transducerHotwordScore > 0)
        #expect(RecognitionHints.transducerHotwordScore < 2.5)
        #expect((1...8).contains(RecognitionHints.transducerBeamWidth))
    }
}
