import Foundation
import Testing

/// Writing check in the iOS keyboard, over a real (temporary) shared
/// container: the keyboard's `WritingCheckClient` running the rules and asking
/// for the model, the app's `TypedGrammarResponder` answering. Darwin pings
/// are skipped for a store with a root override, so each test calls the
/// other side by hand.
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
            text.replacingOccurrences(of: "don't", with: "doesn't")
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

    private func client(appRunning: Bool = true, modelReady: Bool = true) -> WritingCheckClient {
        WritingCheckClient(
            store: store,
            isAppRunning: { appRunning },
            modelReady: { modelReady },
            checker: { Self.checker },
            pause: .milliseconds(10),
            observe: { _ in nil }
        )
    }

    private func type(_ client: WritingCheckClient, _ text: String) async throws {
        client.textChanged(before: text, after: "", enabled: true) { WritingCheckClient.Options() }
        try await Task.sleep(for: .milliseconds(80))
    }

    private func labels(_ client: WritingCheckClient) -> [String] {
        client.report?.suggestions.map(\.label) ?? []
    }

    @Test func theQuestionIsDeletedAsItIsRead() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["He don't know."], keep: []))
        #expect(files() == ["typed-grammar-request.json"])
        #expect(store.takeTypedGrammarRequest()?.sentences == ["He don't know."])
        #expect(files().isEmpty)
        #expect(store.takeTypedGrammarRequest() == nil)
    }

    @Test func aClaimLeftMidReadIsCleared() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("typed-grammar-request.\(UUID().uuidString).taking"))
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["He don't know."], keep: []))
        store.clearTypedGrammarExchange()
        #expect(files().isEmpty)
    }

    @Test func theAppAnswersEachSentence() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let request = TypedGrammarRequest(sentences: ["He don't know.", "Fine."], keep: [])
        try store.saveTypedGrammarRequest(request)
        responder().answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer() == TypedGrammarAnswer(id: request.id, corrected: ["He doesn't know.", "Fine."]))
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
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["He don't know."], keep: [], createdAt: old))
        responder().answerPendingRequest()
        #expect(files().isEmpty)
    }

    @Test func turnedOffInTheAppAnswersWithNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let request = TypedGrammarRequest(sentences: ["He don't know.", "Fine."], keep: [])
        try store.saveTypedGrammarRequest(request)
        responder(enabled: false).answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer() == TypedGrammarAnswer(id: request.id, corrected: [nil, nil]))
    }

    @Test func aModelStillLoadingIsWaitedFor() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Box(0)
        let request = TypedGrammarRequest(sentences: ["He don't know."], keep: [])
        try store.saveTypedGrammarRequest(request)
        responder(correct: { text, _ in
            calls.value += 1
            return calls.value < 3 ? nil : text.replacingOccurrences(of: "don't", with: "doesn't")
        }).answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer()?.corrected == ["He doesn't know."])
    }

    @Test func theRulesAnswerWithoutTheApp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        try await type(client, "He don't know. I could of told you. ")
        #expect(labels(client) == ["of → have"])
        #expect(files().isEmpty)
    }

    @Test func sentencesTheModelHasNotSeenGoToTheApp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        try await type(client, "He don't know. I could of told you. ")
        #expect(labels(client) == ["of → have"])
        #expect(client.report?.modelPending == true)
        responder().answerPendingRequest()
        client.collect()
        #expect(labels(client) == ["don't → doesn't", "of → have"])
        #expect(files().isEmpty)
    }

    @Test func answeredSentencesAreNotAskedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        try await type(client, "He don't know. ")
        responder().answerPendingRequest()
        client.collect()
        try await type(client, "He don't know. They are fine. ")
        #expect(store.takeTypedGrammarRequest()?.sentences == ["They are fine."])
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
        try await type(client, "He don't know. ")
        #expect(files() == ["typed-grammar-request.json"])
        client.reset()
        #expect(files().isEmpty)
        #expect(client.report == nil)
    }

    @Test func theWritingDraftIsTakenOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveWritingDraft("He don't know.")
        #expect(store.takeWritingDraft() == "He don't know.")
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
