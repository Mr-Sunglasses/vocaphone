import Foundation
import Testing

/// Writing check in the iOS keyboard, over a real (temporary) shared
/// container: the keyboard's `WritingCheckClient` running the rules and asking
/// for the model, the app's `TypedGrammarResponder` answering. Darwin pings
/// are skipped for a store with a root override, so each test calls the
/// other side by hand. "She go home." stands for a slip only the model
/// catches; the rules alone do not.
@MainActor
struct WritingCheckExchangeTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var store: SharedStore { SharedStore(rootOverride: root) }
    private static let checker = WritingCheck(rules: WritingCheckTests.rules)

    private func files() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
    }

    private func responder(
        enabled: Bool = true,
        correct: @escaping TypedGrammarResponder.Correct = { text, _ in
            text.replacingOccurrences(of: "She go ", with: "She goes ")
        }
    ) -> TypedGrammarResponder {
        TypedGrammarResponder(
            store: store,
            isEnabled: { enabled },
            correct: correct,
            pollInterval: .milliseconds(5),
            loadWait: .milliseconds(50)
        )
    }

    private func client(
        appRunning: Bool = true,
        modelReady: Bool = true,
        now: @escaping () -> Date = { Date() }
    ) -> WritingCheckClient {
        WritingCheckClient(
            store: store,
            isAppRunning: { appRunning },
            modelReady: { modelReady },
            checker: { Self.checker },
            pause: .milliseconds(10),
            now: now,
            observe: { _ in nil }
        )
    }

    private func type(_ client: WritingCheckClient, _ text: String) async throws {
        client.textChanged(before: text, after: "", enabled: true) { WritingCheckClient.Options() }
        await client.settle()
    }

    /// The app's answer read, and the report rebuilt from it.
    private func collect(_ client: WritingCheckClient) async {
        client.collect()
        await client.settle()
    }

    private func labels(_ client: WritingCheckClient) -> [String] {
        client.report?.suggestions.map(\.label) ?? []
    }

    @Test func theQuestionIsDeletedAsItIsRead() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["She go home."], keep: []))
        #expect(files() == ["typed-grammar-request.json"])
        #expect(store.takeTypedGrammarRequest()?.sentences == ["She go home."])
        #expect(files().isEmpty)
        #expect(store.takeTypedGrammarRequest() == nil)
    }

    @Test func aClaimLeftMidReadIsCleared() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("typed-grammar-request.\(UUID().uuidString).taking"))
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["She go home."], keep: []))
        store.clearTypedGrammarExchange()
        #expect(files().isEmpty)
    }

    @Test func theAppAnswersEachSentence() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let request = TypedGrammarRequest(sentences: ["She go home.", "Fine."], keep: [])
        try store.saveTypedGrammarRequest(request)
        responder().answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer() == TypedGrammarAnswer(id: request.id, corrected: ["She goes home.", "Fine."]))
        #expect(files().isEmpty)
    }

    @Test func theAppPassesTheKeptWordsToTheModel() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Box<Set<String>>([])
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["Ask Kubo."], keep: ["kubo"]))
        responder(correct: { text, keep in
            seen.value = keep
            return text
        }).answerPendingRequest()
        #expect(seen.value == ["kubo"])
    }

    @Test func aStaleQuestionIsDroppedUnanswered() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-TypedGrammarRequest.maximumAge - 1)
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["She go home."], keep: [], createdAt: old))
        responder().answerPendingRequest()
        #expect(files().isEmpty)
    }

    @Test func turnedOffInTheAppAnswersWithNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let request = TypedGrammarRequest(sentences: ["She go home.", "Fine."], keep: [])
        try store.saveTypedGrammarRequest(request)
        responder(enabled: false).answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer() == TypedGrammarAnswer(id: request.id, corrected: [nil, nil]))
    }

    @Test func aModelStillLoadingIsWaitedFor() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Box(0)
        let request = TypedGrammarRequest(sentences: ["She go home."], keep: [])
        try store.saveTypedGrammarRequest(request)
        responder(correct: { text, _ in
            calls.value += 1
            return calls.value < 3 ? nil : text.replacingOccurrences(of: "She go ", with: "She goes ")
        }).answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer()?.corrected == ["She goes home."])
    }

    @Test func theRulesAnswerWithoutTheApp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        try await type(client, "She go home. I could of told you. ")
        #expect(labels(client) == ["of → have"])
        #expect(files().isEmpty)
    }

    @Test func sentencesTheModelHasNotSeenGoToTheApp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        try await type(client, "She go home. I could of told you. ")
        #expect(labels(client) == ["of → have"])
        #expect(client.report?.modelPending == true)
        responder().answerPendingRequest()
        await collect(client)
        #expect(labels(client) == ["go → goes", "of → have"])
        #expect(files().isEmpty)
    }

    @Test func answeredSentencesAreNotAskedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        try await type(client, "She go home. ")
        responder().answerPendingRequest()
        await collect(client)
        try await type(client, "She go home. They are fine. ")
        #expect(store.takeTypedGrammarRequest()?.sentences == ["They are fine."])
    }

    @Test func anExpiredQuestionIsAskedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Box(Date())
        let client = client(now: { clock.value })
        try await type(client, "She go home. ")
        // The app never answered, and the question went unread.
        store.clearTypedGrammarExchange()
        clock.value = clock.value.addingTimeInterval(TypedGrammarRequest.maximumAge + 1)
        try await type(client, "She go home. ")
        #expect(store.takeTypedGrammarRequest()?.sentences == ["She go home."])
    }

    @Test func anEmptyAnswerWaitsForThePauseAndIsNotAskedForever() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        try await type(client, "She go home. ")
        // A model that fails to load answers with nothing.
        responder(enabled: false).answerPendingRequest()
        await collect(client)
        #expect(labels(client).isEmpty)
        #expect(files().isEmpty)
        // The next pause asks once more, and then the rules are left to it.
        try await type(client, "She go home. ")
        responder(enabled: false).answerPendingRequest()
        await collect(client)
        try await type(client, "She go home. ")
        #expect(files().isEmpty)
    }

    @Test func aStaleCheckIsNotPublished() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        client.checkNow(WritingCheckClient.Field(text: "I could of told you. ", cursor: 21), options: .init())
        client.reset()
        await client.settle()
        #expect(client.report == nil)
        #expect(!client.isChecking)
    }

    @Test func aDismissedKeyStaysAwayWithoutItsSuggestion() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        try await type(client, "I could of told you. ")
        let key = try #require(client.report?.suggestions.first).key
        client.applied(try #require(client.report?.suggestions.first))
        #expect(labels(client).isEmpty)
        // Undo: the words are back, and the fix is not offered again.
        client.dismiss(key: key)
        try await type(client, "I could of told you. ")
        #expect(labels(client).isEmpty)
    }

    @Test func fixesBeyondTheWindowCannotBeAccepted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        let text = "I could of told you. Sure. They could of known."
        let cursor = ("I could of told you. Sure. " as NSString).length
        client.checkNow(
            WritingCheckClient.Field(text: text, cursor: cursor, reach: (cursor - 6)..<text.utf16.count),
            options: .init()
        )
        await client.settle()
        let report = try #require(client.report)
        #expect(report.suggestions.count == 2)
        #expect(report.suggestions.filter(report.canApply).map(\.start) == [cursor + 11])
        #expect(report.chips.map(\.start) == [cursor + 11])
    }

    @Test func aWindowOntoTheWholeMessageKeepsItsReport() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        let before = "I could of told you. Sure. "
        let after = "They could of known."
        let cursor = (before as NSString).length
        client.checkNow(WritingCheckClient.Field(text: before + after, cursor: cursor, reach: 0..<cursor), options: .init())
        await client.settle()
        #expect(client.report?.count == 2)
        client.textChanged(before: "Sure. ", after: "They could", enabled: true) { WritingCheckClient.Options() }
        await client.settle()
        let report = try #require(client.report)
        #expect(report.count == 2)
        #expect(report.field.reach == (cursor - 6)..<(cursor + 10))
    }

    @Test func undoFindsTheFixWhereItWasMade() throws {
        let text = "thier car is their responsibility "
        let field = WritingCheckClient.Field(text: text, cursor: (text as NSString).length)
        let fix = try #require(WritingAutoFix(suggestion(text, "thier", "their", at: 0), in: field))
        let fixed = "their car is their responsibility "
        #expect(fix.isCurrent(before: fixed))
        // Back from the cursor to the end of the first "their", not the second.
        #expect(fix.distance == ((" car is their responsibility ") as NSString).length)
        #expect(!fix.isCurrent(before: fixed + "x"))
        #expect(!fix.isCurrent(before: "their car is their"))
        #expect(!fix.isCurrent(before: nil))
    }

    private func suggestion(_ text: String, _ original: String, _ replacement: String, at start: Int) -> WritingSuggestion {
        let end = start + (original as NSString).length
        return WritingSuggestion(
            start: start, end: end, original: original, replacement: replacement,
            markStart: start, markEnd: end, kind: "spelling", category: .correctness,
            title: "Spelling", message: "", mechanical: true, source: .rule, rule: nil
        )
    }

    @Test func aDismissedSuggestionStaysAway() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        try await type(client, "I could of told you. ")
        client.dismiss(try #require(client.report?.suggestions.first))
        try await type(client, "I could of told you. Sure. ")
        #expect(labels(client).isEmpty)
    }

    @Test func applyingMovesTheOthers() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        try await type(client, "I definately could of told you. ")
        client.applied(try #require(client.report?.suggestions.first))
        let report = try #require(client.report)
        #expect(report.field.text == "I definitely could of told you. ")
        let rest = try #require(report.suggestions.first)
        #expect(report.field.text.utf16Slice(rest.start, rest.end) == "of")
    }

    @Test func resetRemovesTheQuestionFromTheAppGroup() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        try await type(client, "She go home. ")
        #expect(files() == ["typed-grammar-request.json"])
        client.reset()
        #expect(files().isEmpty)
        #expect(client.report == nil)
    }

    @Test func theWritingDraftIsTakenOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveWritingDraft("She go home.")
        #expect(store.takeWritingDraft() == "She go home.")
        #expect(store.takeWritingDraft() == nil)
        try store.saveWritingDraft("Old.")
        #expect(store.takeWritingDraft(now: Date().addingTimeInterval(WritingDraft.maximumAge + 1)) == nil)
    }
}

/// A mutable cell a `@Sendable` closure can write to in a test.
private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
