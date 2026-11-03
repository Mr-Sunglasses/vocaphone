import Foundation
import Testing

/// Matches the Android client's `ContextTermsTest`. The extraction cases are
/// VocaMac's `ScreenContextTermsTests`, which this is ported from.
struct ContextTermsTests {
    private static let common: Set<String> = [
        "func", "let", "ping", "about", "the", "and", "keys", "in", "tomorrow", "we", "ship",
        "check", "apple", "notes", "and", "so", "on", "send", "email", "setup", "now", "open",
        "push", "it", "to", "ask", "call", "by", "id", "get", "user", "hi", "can", "you",
        "please", "bump", "export", "then",
    ]
    private let isKnown: (String) -> Bool = { common.contains($0.lowercased()) }

    // MARK: - Extraction

    @Test func extractsIdentifiersAndNames() {
        let text = """
        func loadUser(userId: String) { let max_retries = 3 }
        Ping Namrata about the GitHub and OpenAI keys in api-client.
        """
        let terms = ContextTerms.extract(from: text, isKnownWord: isKnown)
        for expected in ["loadUser", "userId", "max_retries", "Namrata", "GitHub", "OpenAI", "api-client"] {
            #expect(terms.contains(expected), "\(expected) in \(terms)")
        }
    }

    @Test func skipsSentenceStartsAndOrdinaryCapitalizedWords() {
        let terms = ContextTerms.extract(from: "Tomorrow we ship. Check the Apple notes.", isKnownWord: isKnown)
        #expect(!terms.contains("Tomorrow"))
        #expect(!terms.contains("Check"))
        #expect(!terms.contains("Apple"))
    }

    @Test func mostRelevantTermsComeFirst() {
        let filler = String(repeating: "and so on ", count: 40)
        let text = "farAwayName " + filler + "nearCaret " + filler + "lastName repeatedTerm repeatedTerm"
        let terms = ContextTerms.extract(from: text, isKnownWord: isKnown)
        // Shown twice beats shown once; then nearest the caret, here the middle.
        #expect(terms.first == "repeatedTerm")
        #expect(terms.dropFirst().first == "nearCaret")
        #expect(Set(terms) == ["repeatedTerm", "nearCaret", "farAwayName", "lastName"])
    }

    @Test func theCursorIsWhereNearnessIsMeasuredFrom() {
        let filler = String(repeating: "and so on ", count: 20)
        let terms = ContextTerms.extract(
            before: "Hi Namrata, " + filler + "can you ask Siddharth ",
            after: filler + "about Kubernetes",
            isKnownWord: isKnown
        )
        #expect(terms == ["Siddharth", "Kubernetes", "Namrata"])
    }

    @Test func deduplicatesAndCaps() {
        let text = (0..<400).map { "varName\($0)" }.joined(separator: " ") + " varName0"
        let terms = ContextTerms.extract(from: text, isKnownWord: isKnown)
        #expect(terms.count == ContextTerms.maximumTerms)
        #expect(terms.first == "varName0")
    }

    @Test func readsAThousandCharactersEitherSideOfTheCursor() {
        let filler = String(repeating: "x", count: ContextTerms.maximumCharactersEachSide)
        let terms = ContextTerms.extract(
            before: "farBefore " + filler,
            after: filler + " farAfter",
            isKnownWord: isKnown
        )
        #expect(terms.isEmpty)
        #expect(ContextTerms.extract(before: "nearBefore " + filler.dropFirst(11), after: nil, isKnownWord: isKnown)
            == ["nearBefore"])
    }

    @Test func acronymsThatAreNotOrdinaryWords() {
        let terms = ContextTerms.extract(from: "PLEASE bump CUDA and the ONNX export, then OAuth.", isKnownWord: isKnown)
        #expect(Set(terms) == ["CUDA", "ONNX", "OAuth"])
    }

    @Test func withoutAWordListOnlyTheShapesAreKept() {
        let terms = ContextTerms.extract(from: "Ping Namrata about GitHub.") { _ in true }
        #expect(terms == ["GitHub"])
    }

    @Test func aWordInsideALongerOneIsNotATerm() {
        // Accented letters and underscores continue a word, as `\b` would say.
        #expect(ContextTerms.extract(from: "see ÉcoleTest and _privateName", isKnownWord: isKnown).isEmpty)
    }

    // MARK: - Correction

    private func correct(_ text: String, _ terms: [String], vocabulary: [String] = []) -> String {
        ContextTerms.correct(text, terms: terms, vocabulary: vocabulary, isDictionaryWord: isKnown)
    }

    @Test func spellsAnExactLetterMatchTheWayTheFieldDoes() {
        #expect(correct("push it to git hub now", ["GitHub"]) == "push it to GitHub now")
        #expect(correct("ask namrata about it", ["Namrata"]) == "ask Namrata about it")
        #expect(correct("Github's down", ["GitHub"]) == "GitHub's down")
    }

    @Test func neverANearMiss() {
        #expect(correct("ask namrta about it", ["Namrata"]) == "ask namrta about it")
        #expect(correct("push it to git hubs", ["GitHub"]) == "push it to git hubs")
    }

    @Test func theUsersOwnSpellingWins() {
        #expect(correct("open Vocaphone", ["VOCAPHONE"], vocabulary: ["Vocaphone"]) == "open Vocaphone")
        #expect(correct("open vocaphone", ["VocaPhone"], vocabulary: ["Vocaphone"]) == "open vocaphone")
    }

    @Test func anOrdinaryWordIsNeverRespelled() {
        #expect(correct("send the email now", ["e-mail"]) == "send the email now")
        #expect(correct("send the setup now", ["setUp"]) == "send the setup now")
        #expect(correct("check the apple notes", ["APPLE"]) == "check the apple notes")
        // A word that is not one still takes the field's spelling.
        #expect(correct("open vocamac now", ["voca-mac"]) == "open voca-mac now")
    }

    @Test func anIdentifierNeverJoinsWords() {
        #expect(correct("call get user by id", ["getUserById"]) == "call get user by id")
        #expect(correct("call getuserbyid", ["getUserById"]) == "call getUserById")
    }

    @Test func aProtectedWordIsLeftAlone() {
        let text = "git hub sig"
        let range = text.range(of: "git")!
        #expect(ContextTerms.correct(text, terms: ["GitHub"], protectedRanges: [range]) == text)
    }

    @Test func isIdentifierShaped() {
        #expect(ContextTerms.isIdentifierShaped("userId"))
        #expect(ContextTerms.isIdentifierShaped("iPhone"))
        #expect(ContextTerms.isIdentifierShaped("max_retries"))
        #expect(ContextTerms.isIdentifierShaped("api-client"))
        #expect(ContextTerms.isIdentifierShaped("varName0"))
        #expect(!ContextTerms.isIdentifierShaped("GitHub"))
        #expect(!ContextTerms.isIdentifierShaped("Namrata"))
    }

    // MARK: - The funnel

    @Test func theFunnelSpellsContextTermsAfterTheVocabulary() {
        func finish(_ raw: String, style: WritingStyle = .casual, vocabulary: [String] = []) -> String {
            // Styled upstream, so the words are exactly the ones checked.
            DictatedTranscript.finished(
                raw, style: style, language: "en", styledUpstream: true, repairSpeech: false, numbersAsDigits: false,
                spokenEmoji: false, snippets: [], vocabulary: vocabulary,
                isDictionaryWord: { Self.common.contains($0) },
                contextTerms: ["GitHub", "Namrata"]
            )
        }
        #expect(finish("ask namrata to push it to git hub") == "ask Namrata to push it to GitHub")
        #expect(finish("ask namrata", style: .raw) == "ask namrata")
        #expect(finish("ask namrata", vocabulary: ["NAMRATA"]) == "ask NAMRATA")
    }

    @Test func contextTermsReachTheHintsAfterTheUsersOwnWords() {
        let terms = RecognitionHints.terms(vocabulary: ["Kanishk"], contextTerms: ["GitHub", "Namrata"])
        #expect(RecognitionHints.whisperPrompt(terms) == "Kanishk, GitHub, Namrata.")
        #expect(RecognitionHints.qwen3Hotwords(terms) == "Kanishk,GitHub,Namrata")
        let settings = WhisperDictationSettings(
            language: "en", translate: false, quality: .default, vocabulary: "Kanishk", contextTerms: ["GitHub"]
        )
        #expect(settings.hintTerms == ["GitHub", "Kanishk"])
    }

    @Test func qwen3TakesContextTermsWithoutAListOfTheUsers() throws {
        let qwen = try #require(LocalModelCatalog.descriptor(for: "qwen3-asr-0.6b"))
        let hotwords = RecognitionHints.sherpaHotwords(
            for: qwen, vocabulary: [], replacementTargets: [], contextTerms: ["GitHub", "Namrata"]
        )
        #expect(hotwords == "GitHub,Namrata")
    }

    @Test func withNoListOfTheUsersContextKeepsParakeetUnifiedOnGreedySearchEverywhere() throws {
        let unified = try #require(LocalModelCatalog.descriptor(for: "parakeet-unified-0.6b-en"))
        // The warm-up, the incremental session and the whole-file decode all
        // build the recognizer through `LocalModelManager.hotwordVocabulary(for:)`,
        // which asks this.
        #expect(!RecognitionHints.takesHotwordSearch(unified, vocabulary: [], replacementTargets: []))
        // And the decode hands a greedy recognizer no hotwords, whatever the cursor held.
        let hotwords = RecognitionHints.sherpaHotwords(
            for: unified, vocabulary: [], replacementTargets: [], contextTerms: ["GitHub", "Namrata"]
        )
        #expect(hotwords == nil)
    }

    @Test func withAListOfTheUsersContextJoinsParakeetUnifiedsHotwordsAfterIt() throws {
        let unified = try #require(LocalModelCatalog.descriptor(for: "parakeet-unified-0.6b-en"))
        #expect(RecognitionHints.takesHotwordSearch(unified, vocabulary: ["Kanishk"], replacementTargets: []))
        let context = ["GitHub", "Namrata"]
        #expect(RecognitionHints.sherpaHotwords(
            for: unified, vocabulary: ["Kanishk"], replacementTargets: [], contextTerms: context
        ) == "Kanishk/GitHub/Namrata")
        #expect(RecognitionHints.sherpaHotwords(
            for: unified, vocabulary: [], replacementTargets: ["Kanishk"], contextTerms: context
        ) == "Kanishk/GitHub/Namrata")
        // The 64-term cap cuts the cursor's terms, never the user's.
        let user = (1...60).map { "User\($0)" }
        let screen = (1...30).map { "Screen\($0)" }
        let kept = try #require(RecognitionHints.sherpaHotwords(
            for: unified, vocabulary: user, replacementTargets: [], contextTerms: screen
        )).split(separator: "/").map(String.init)
        #expect(kept.count == RecognitionHints.maximumTransducerHotwords)
        #expect(Array(kept.prefix(60)) == user)
        #expect(Array(kept.dropFirst(60)) == ["Screen1", "Screen2", "Screen3", "Screen4"])
    }

    // MARK: - Hand-off

    @Test func theAppTakesTheTermsOnceAndTheyAreGone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SharedStore(rootOverride: root)
        let id = UUID()
        try store.saveCursorContextTerms(["GitHub", "Namrata"], for: id)
        #expect(store.takeCursorContextTerms(for: id) == ["GitHub", "Namrata"])
        #expect(store.takeCursorContextTerms(for: id).isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path)
        #expect(left.isEmpty)
    }

    @Test func termsNobodyTookGoWithTheSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SharedStore(rootOverride: root)
        var record = SessionRecord()
        try store.saveCursorContextTerms(["GitHub"], for: record.sessionID)
        try record.transition(to: .launchingApp)
        try store.save(record)
        // Still waiting for the app to claim it.
        #expect(store.takeCursorContextTerms(for: record.sessionID) == ["GitHub"])

        try store.saveCursorContextTerms(["GitHub"], for: record.sessionID)
        try record.transition(to: .canceled)
        try store.save(record)
        #expect(store.takeCursorContextTerms(for: record.sessionID).isEmpty)

        let other = SessionRecord()
        try store.save(other)
        try store.saveCursorContextTerms(["Namrata"], for: other.sessionID)
        try store.delete(other.sessionID)
        #expect(store.takeCursorContextTerms(for: other.sessionID).isEmpty)
    }

    @Test func atMostAHundredTermsAreHandedOver() {
        #expect(CursorContextTerms(terms: (0..<300).map { "term\($0)" }).terms.count == ContextTerms.maximumTerms)
    }
}
