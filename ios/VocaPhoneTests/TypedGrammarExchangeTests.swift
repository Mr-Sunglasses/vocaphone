import Foundation
import Testing

/// Both halves of "Check grammar while typing" over a real (temporary) shared
/// container: the keyboard's `TypedGrammarClient` asking, the app's
/// `TypedGrammarResponder` answering. Darwin pings are skipped for a store with
/// a root override, so each test calls the other side by hand.
@MainActor
struct TypedGrammarExchangeTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var store: SharedStore { SharedStore(rootOverride: root) }

    private func files() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
    }

    private func responder(
        enabled: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() },
        answerLifetime: Duration = .seconds(TypedGrammarRequest.maximumAge),
        correct: @escaping TypedGrammarResponder.Correct = { text, _ in
            text.replacingOccurrences(of: "don't", with: "doesn't")
        }
    ) -> TypedGrammarResponder {
        TypedGrammarResponder(
            store: store,
            isEnabled: { enabled },
            correct: correct,
            now: now,
            pollInterval: .milliseconds(5),
            loadWait: .milliseconds(50),
            answerLifetime: answerLifetime
        )
    }

    private func client(
        appRunning: Bool = true,
        now: @escaping () -> Date = { Date() },
        observe: @escaping (@escaping @Sendable () -> Void) -> VocaPhoneDarwinObservation? = { _ in nil }
    ) -> TypedGrammarClient {
        TypedGrammarClient(
            store: store,
            isAppRunning: { appRunning },
            pause: .milliseconds(10),
            now: now,
            observe: observe
        )
    }

    /// Lets the client's pause run out.
    private func pause() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    @Test func theQuestionIsDeletedAsItIsRead() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveTypedGrammarRequest(TypedGrammarRequest(text: "He don't know.", keep: []))
        #expect(files() == ["typed-grammar-request.json"])
        #expect(store.takeTypedGrammarRequest()?.text == "He don't know.")
        #expect(files().isEmpty)
        #expect(store.takeTypedGrammarRequest() == nil)
    }

    /// Review finding: reading then deleting in place could delete, unread, a
    /// newer question saved in between. The file is claimed by a rename, and
    /// a claim left by a process that ended mid-read is cleared at start.
    @Test func aClaimLeftMidReadIsCleared() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let left = root.appendingPathComponent("typed-grammar-request.\(UUID().uuidString).taking")
        try Data("{}".utf8).write(to: left)
        try store.saveTypedGrammarRequest(TypedGrammarRequest(text: "He don't know.", keep: []))
        store.clearTypedGrammarExchange()
        #expect(files().isEmpty)
    }

    @Test func theAppAnswersWithTheModelsText() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let request = TypedGrammarRequest(text: "He don't know.", keep: [])
        try store.saveTypedGrammarRequest(request)
        responder().answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer() == TypedGrammarAnswer(id: request.id, corrected: "He doesn't know."))
        #expect(files().isEmpty)
    }

    @Test func theAppPassesTheKeptWordsToTheModel() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Box<Set<String>>([])
        try store.saveTypedGrammarRequest(TypedGrammarRequest(text: "Ask Kubo.", keep: ["kubo"]))
        responder(correct: { text, keep in
            seen.value = keep
            return text
        }).answerPendingRequest()
        #expect(seen.value == ["kubo"])
    }

    @Test func aStaleQuestionIsDroppedUnanswered() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-TypedGrammarRequest.maximumAge - 1)
        try store.saveTypedGrammarRequest(TypedGrammarRequest(text: "He don't know.", keep: [], createdAt: old))
        responder().answerPendingRequest()
        #expect(files().isEmpty)
    }

    @Test func turnedOffInTheAppAnswersWithNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let request = TypedGrammarRequest(text: "He don't know.", keep: [])
        try store.saveTypedGrammarRequest(request)
        responder(enabled: false).answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer() == TypedGrammarAnswer(id: request.id, corrected: nil))
    }

    @Test func aModelStillLoadingIsWaitedFor() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Box(0)
        let request = TypedGrammarRequest(text: "He don't know.", keep: [])
        try store.saveTypedGrammarRequest(request)
        responder(correct: { text, _ in
            calls.value += 1
            return calls.value < 3 ? nil : "He doesn't know."
        }).answerPendingRequest()
        #expect(calls.value == 3)
        #expect(store.takeTypedGrammarAnswer()?.corrected == "He doesn't know.")
    }

    @Test func aModelThatNeverLoadsIsGivenUpOn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let request = TypedGrammarRequest(text: "He don't know.", keep: [])
        try store.saveTypedGrammarRequest(request)
        responder(correct: { _, _ in nil }).answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer() == TypedGrammarAnswer(id: request.id, corrected: nil))
    }

    /// Review finding: an answer written after the keyboard closed stayed on
    /// disk until the next exchange.
    @Test func anUncollectedAnswerIsDeletedOnceTheKeyboardWouldNoLongerTakeIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveTypedGrammarRequest(TypedGrammarRequest(text: "He don't know.", keep: []))
        responder(answerLifetime: .milliseconds(20)).answerPendingRequest()
        #expect(files() == ["typed-grammar-answer.json"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(files().isEmpty)
    }

    /// A newer answer is not removed by an older one's expiry.
    @Test func anExpiryLeavesANewerAnswer() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveTypedGrammarRequest(TypedGrammarRequest(text: "He don't know.", keep: []))
        responder(answerLifetime: .milliseconds(20)).answerPendingRequest()
        let newer = TypedGrammarAnswer(id: UUID(), corrected: "Fine.")
        try store.saveTypedGrammarAnswer(newer)
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.takeTypedGrammarAnswer() == newer)
    }

    /// A check that outlasts the keyboard's patience is not answered: the
    /// keyboard has already asked again, and the answer would only wait on disk.
    @Test func aQuestionThatGoesStaleWhileCheckingIsNotAnswered() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Box(Date())
        try store.saveTypedGrammarRequest(TypedGrammarRequest(text: "He don't know.", keep: [], createdAt: clock.value))
        responder(now: { clock.value }, correct: { text, _ in
            clock.value = clock.value.addingTimeInterval(TypedGrammarRequest.maximumAge + 1)
            return text
        }).answerPendingRequest()
        #expect(files().isEmpty)
    }

    @Test func startingClearsWhatAnEarlierProcessLeft() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveTypedGrammarRequest(TypedGrammarRequest(text: "Left over.", keep: []))
        try store.saveTypedGrammarAnswer(TypedGrammarAnswer(id: UUID(), corrected: "Left over."))
        let responder = responder()
        responder.start()
        defer { responder.stop() }
        #expect(files().isEmpty)
    }

    // MARK: - The keyboard's side

    @Test func aPauseAsksAndTheAnswerBecomesAFix() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        #expect(files() == ["typed-grammar-request.json"])
        responder().answerPendingRequest()
        client.collect()
        #expect(client.fix?.label == "don't \u{2192} doesn't")
        #expect(files().isEmpty)
    }

    /// Review finding: the first question was written before the answer's
    /// listener registered, so a quick answer could ping nobody.
    @Test func theKeyboardListensBeforeItAsks() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let seenAtRegistration = Box<[String]?>(nil)
        let client = client(observe: { [root] _ in
            seenAtRegistration.value =
                (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return nil
        })
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        #expect(seenAtRegistration.value == [])
        #expect(files() == ["typed-grammar-request.json"])
    }

    @Test func nothingIsAskedWhileTheAppIsNotRunning() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        #expect(files().isEmpty)
    }

    @Test func nothingIsAskedMidWord() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        client.textChanged(before: "He don't kno", enabled: true, keep: { [] })
        try await pause()
        #expect(files().isEmpty)
    }

    @Test func anotherLanguageIsNotAsked() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        client.isEnglish = { _ in false }
        client.textChanged(before: "Er weiß es nicht. ", enabled: true, keep: { [] })
        try await pause()
        #expect(files().isEmpty)
    }

    @Test func anAnswerToAnOlderQuestionIsDropped() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        _ = store.takeTypedGrammarRequest()
        try store.saveTypedGrammarAnswer(TypedGrammarAnswer(id: UUID(), corrected: "He doesn't know."))
        client.collect()
        #expect(client.fix == nil)
    }

    @Test func typingOnBeforeTheAnswerLandsDropsIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        responder().answerPendingRequest()
        client.textChanged(before: "He don't know. And", enabled: true, keep: { [] })
        client.collect()
        #expect(client.fix == nil)
    }

    @Test func aDismissedFixStaysAwayInThisField() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        responder().answerPendingRequest()
        client.collect()
        client.dismiss()
        #expect(client.fix == nil)
        client.textChanged(before: "He don't know. It is fine. ", enabled: true, keep: { [] })
        try await pause()
        responder().answerPendingRequest()
        client.collect()
        #expect(client.fix == nil)
    }

    @Test func turningItOffDropsTheFix() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        responder().answerPendingRequest()
        client.collect()
        client.textChanged(before: "He don't know. ", enabled: false, keep: { [] })
        #expect(client.fix == nil)
    }

    /// Review finding: an answer computed while checking was being turned off
    /// brought the fix back.
    @Test func anAnswerLandingAfterCheckingStopsIsDropped() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        let request = try #require(store.takeTypedGrammarRequest())
        client.textChanged(before: "He don't know. ", enabled: false, keep: { [] })
        try store.saveTypedGrammarAnswer(TypedGrammarAnswer(id: request.id, corrected: "He doesn't know."))
        client.collect()
        #expect(client.fix == nil)
    }

    @Test func turningItOffRemovesTheQuestionInFlight() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        client.textChanged(before: nil, enabled: true, keep: { [] })
        #expect(files().isEmpty)
    }

    /// Review finding: a question nobody answered blocked its sentence for good.
    @Test func anUnansweredQuestionExpiresAndTheSentenceIsAskedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Box(Date())
        let client = client(now: { clock.value })
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        let first = try #require(store.takeTypedGrammarRequest())
        // Asked again before it expires: still waiting, nothing written.
        client.textChanged(before: "He don't know.  ", enabled: true, keep: { [] })
        try await pause()
        #expect(store.takeTypedGrammarRequest() == nil)
        clock.value = clock.value.addingTimeInterval(TypedGrammarRequest.maximumAge + 1)
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        let second = try #require(store.takeTypedGrammarRequest())
        #expect(second.text == first.text)
        #expect(second.id != first.id)
    }

    /// Review finding: personal words were not protected. They are now, but
    /// only the ones in the sentence travel: the list includes every contact.
    @Test func onlyTheProtectedWordsInTheSentenceAreSent() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        client.textChanged(
            before: "Ask Kubo if he don't know. ",
            enabled: true,
            keep: { ["kubo", "zanele", "don't"] }
        )
        try await pause()
        #expect(store.takeTypedGrammarRequest()?.keep == ["kubo", "don't"])
    }

    @Test func resetRemovesAnUncollectedQuestion() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        client.textChanged(before: "He don't know. ", enabled: true, keep: { [] })
        try await pause()
        client.reset()
        #expect(files().isEmpty)
    }
}

/// A mutable cell a `@Sendable` closure can write to in a test.
private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
