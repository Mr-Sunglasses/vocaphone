import Foundation
import Testing

/// "Heard → written" replacements, on their own and in the finishing funnel.
/// Ported from VocaMac's replacement tests; mirrored by `WordReplacementTest.kt`.
struct WordReplacementTests {
    private func replaced(_ text: String, _ replacements: [WordReplacement]) -> String {
        WordReplacements.apply(text, replacements: replacements).text
    }

    @Test func ignoresCaseAndWritesTheUsersSpelling() {
        let result = WordReplacements.apply(
            "Push it to get hub please", replacements: [WordReplacement(heard: "get hub", written: "GitHub")]
        )
        #expect(result.text == "Push it to GitHub please")
        #expect(result.written.map { String(result.text[$0]) } == ["GitHub"])
        #expect(replaced("Get Hub is down.", [WordReplacement(heard: "get hub", written: "GitHub")]) == "GitHub is down.")
    }

    @Test func matchesWholeWordsOnly() {
        #expect(replaced("the cattle and the cat", [WordReplacement(heard: "cat", written: "Kat")])
            == "the cattle and the Kat")
        #expect(replaced("concatenate", [WordReplacement(heard: "cat", written: "Kat")]) == "concatenate")
        // A possessive or a full stop after the heard form is fine.
        #expect(replaced("the cat's bowl.", [WordReplacement(heard: "cat", written: "Kat")]) == "the Kat's bowl.")
    }

    @Test func acceptsSeveralHeardForms() {
        let replacement = WordReplacement(heard: "cube cuttle, cube  control", written: "kubectl")
        #expect(replacement.heardForms == ["cube cuttle", "cube control"])
        #expect(replaced("run cube cuttle then Cube Control", [replacement]) == "run kubectl then kubectl")
    }

    @Test func theLongerHeardFormWins() {
        let replacements = [
            WordReplacement(heard: "open ai", written: "OpenAI"),
            WordReplacement(heard: "open ai studio", written: "AI Studio"),
        ]
        #expect(replaced("open ai studio", replacements) == "AI Studio")
        #expect(replaced("ask open ai", replacements) == "ask OpenAI")
    }

    /// One pass: what a replacement wrote is never matched again.
    @Test func aWrittenFormIsNotReplacedAgain() {
        let replacements = [
            WordReplacement(heard: "jay", written: "J K"),
            WordReplacement(heard: "k", written: "Kay"),
        ]
        #expect(replaced("jay", replacements) == "J K")
    }

    @Test func protectedRangesAreLeftAlone() {
        let text = "send get hub now"
        let trigger = text.range(of: "get hub")!
        let result = WordReplacements.apply(
            text, replacements: [WordReplacement(heard: "get hub", written: "GitHub")], protectedRanges: [trigger]
        )
        #expect(result.text == text)
        #expect(result.written.isEmpty)
    }

    @Test func aHeardFormWithPunctuationNeedsSpaceAroundIt() {
        let replacement = WordReplacement(heard: "c++", written: "C++")
        #expect(replaced("I write c++ daily", [replacement]) == "I write C++ daily")
        #expect(replaced("abc++", [replacement]) == "abc++")
    }

    @Test func invalidRowsDoNothing() {
        #expect(!WordReplacement(heard: " , ", written: "X").isValid)
        #expect(!WordReplacement(heard: "x", written: "  ").isValid)
        #expect(replaced("x marks", [WordReplacement(heard: "x", written: " ")]) == "x marks")
        #expect(replaced("", [WordReplacement(heard: "x", written: "Y")]) == "")
    }

    @Test func hintTargetsAreTheValidWrittenForms() {
        let replacements = [
            WordReplacement(heard: "get hub", written: "GitHub"),
            WordReplacement(heard: "", written: "Nothing"),
            WordReplacement(heard: "my mail", written: "me@example.com"),
        ]
        #expect(WordReplacements.hintTargets(replacements) == ["GitHub", "me@example.com"])
        // RecognitionHints decides which of them reads like a term.
        #expect(RecognitionHints.terms(
            vocabulary: [], replacementTargets: WordReplacements.hintTargets(replacements)
        ) == ["GitHub"])
    }

    // MARK: - Adding

    @Test func addingJoinsARowWithTheSameWrittenForm() {
        var list = WordReplacements.adding(heard: "get hub", written: "GitHub", to: [])
        list = WordReplacements.adding(heard: "git  hub", written: "GitHub", to: list)
        #expect(list.count == 1)
        #expect(list[0].heardForms == ["get hub", "git hub"])
    }

    @Test func addingMovesAHeardFormToItsNewRow() {
        var list = WordReplacements.adding(heard: "cube control", written: "kubectl", to: [])
        list = WordReplacements.adding(heard: "Cube Control", written: "KubeControl", to: list)
        #expect(list.map(\.written) == ["KubeControl"])
        #expect(list[0].heardForms == ["Cube Control"])
    }

    @Test func aCombiningMarkBelongsToTheWordItFollows() {
        let tomorrow = WordReplacement(heard: "कल", written: "tomorrow")
        #expect(WordReplacements.apply("कला", replacements: [tomorrow]).text == "कला")
        #expect(WordReplacements.apply("कल कला", replacements: [tomorrow]).text == "tomorrow कला")
    }

    @Test func addingTakesEveryHeardFormTypedWithCommas() {
        let list = WordReplacements.adding(heard: "get hub, git hub", written: "GitHub", to: [])
        #expect(list.count == 1)
        #expect(list.first?.heardForms == ["get hub", "git hub"])
        #expect(list.first?.written == "GitHub")
        // A form another row had moves, as a single form does.
        let moved = WordReplacements.adding(heard: "git hub, gee hub", written: "Gitea", to: list)
        #expect(moved.first { $0.written == "GitHub" }?.heardForms == ["get hub"])
        #expect(moved.first { $0.written == "Gitea" }?.heardForms == ["git hub", "gee hub"])
    }

    @Test func addingRejectsWhatCannotMatch() {
        #expect(WordReplacements.adding(heard: " , ", written: "C", to: []).isEmpty)
        #expect(WordReplacements.adding(heard: " ", written: "C", to: []).isEmpty)
        #expect(WordReplacements.adding(heard: "a", written: " ", to: []).isEmpty)
    }

    @Test func storedAsJSONAndUnreadableStorageIsEmpty() throws {
        let list = [WordReplacement(heard: "get hub", written: "GitHub")]
        let data = try #require(WordReplacement.encode(list))
        #expect(WordReplacement.decode(data) == list)
        #expect(WordReplacement.decode(Data("not json".utf8)).isEmpty)
        #expect(WordReplacement.decode(nil).isEmpty)
    }

    // MARK: - In the funnel

    private func finished(
        _ raw: String,
        style: WritingStyle = .casual,
        language: String = "en",
        snippets: [Snippet] = [],
        vocabulary: [String] = [],
        replacements: [WordReplacement],
        unsure: Set<String>? = nil
    ) -> String {
        DictatedTranscript.finished(
            raw,
            style: style,
            language: language,
            repairSpeech: false,
            numbersAsDigits: true,
            spokenEmoji: false,
            snippets: snippets,
            vocabulary: vocabulary,
            replacements: replacements,
            lowConfidenceWords: unsure,
            isDictionaryWord: { ["push", "it", "to", "please", "deploy", "cooper", "netties", "now"].contains($0) }
        )
    }

    private let gitHub = WordReplacement(heard: "get hub", written: "GitHub")

    /// After styling, so sentence case cannot undo the user's spelling.
    @Test func replacementsComeAfterStyling() {
        let lower = WordReplacement(heard: "cube control", written: "kubectl")
        #expect(finished("cube control is slow", style: .formal, replacements: [lower]) == "kubectl is slow.")
        #expect(finished("push it to get hub please", replacements: [gitHub]) == "Push it to GitHub please")
    }

    @Test func rawGetsNoReplacements() {
        #expect(finished("get hub", style: .raw, replacements: [gitHub]) == "get hub")
    }

    @Test func everyLanguageGetsReplacements() {
        #expect(finished("schick es an get hub", language: "de", replacements: [gitHub]) == "Schick es an GitHub")
    }

    @Test func aSnippetTriggerIsNeverReplaced() {
        let snippet = Snippet(trigger: "get hub", expansion: "https://github.com/me")
        #expect(finished("open get hub", snippets: [snippet], replacements: [gitHub]) == "Open https://github.com/me")
    }

    /// Custom words leave a replacement's text alone: "GitHub" is not a near
    /// miss of anything once the user has said what it is.
    @Test func customWordsDoNotTouchWhatAReplacementWrote() {
        let replacement = WordReplacement(heard: "vocal phone", written: "Vocalphone")
        #expect(finished("try vocal phone", vocabulary: ["VocaPhone"], replacements: [replacement]) == "Try Vocalphone")
        #expect(finished("try vocal phone", vocabulary: ["VocaPhone"], replacements: []) == "Try VocaPhone")
    }

    @Test func theEnginesDoubtReachesCorrection() {
        let text = "deploy to cooper netties now"
        #expect(finished(text, vocabulary: ["Kubernetes"], replacements: [], unsure: ["netties"])
            == "Deploy to Kubernetes now")
        #expect(finished(text, vocabulary: ["Kubernetes"], replacements: [], unsure: [])
            == "Deploy to cooper netties now")
        #expect(finished(text, vocabulary: ["Kubernetes"], replacements: [], unsure: nil)
            == "Deploy to cooper netties now")
    }
}
