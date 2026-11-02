import Foundation

/// The app's half of Writing check in the keyboard: the grammar model.
///
/// The keyboard extension cannot load the grammar model, so it writes the
/// sentences it wants checked to the App Group and pings; this answers with
/// the model's text. It only hears the ping while the app is running — which,
/// for a keyboard user, is while Quick Dictation keeps it in the background —
/// and the keyboard does not ask otherwise.
///
/// The question is deleted as it is read and the answer is deleted by the
/// keyboard as it reads it. An answer the keyboard never collects — it closed
/// while the app was checking — is deleted by the app once the keyboard would
/// no longer take it, `answerLifetime` later. Nothing is logged but the grammar stage's own
/// content-free events, and nothing reaches usage statistics.
final class TypedGrammarResponder: @unchecked Sendable {
    /// A sentence, the words to keep, and whether the user asked for the check.
    typealias Correct = @Sendable (String, Set<String>, Bool) -> String?

    private let store: SharedStore
    private let isEnabled: @Sendable () -> Bool
    private let correct: Correct
    private let now: @Sendable () -> Date
    private let pollInterval: Duration
    private let loadWait: Duration
    private let answerLifetime: Duration
    private let queue = DispatchQueue(label: "com.vocahq.vocaphone.typed-grammar", qos: .userInitiated)
    private var observation: VocaPhoneDarwinObservation?

    init(
        store: SharedStore = .shared,
        isEnabled: @escaping @Sendable () -> Bool,
        correct: @escaping Correct,
        now: @escaping @Sendable () -> Date = { Date() },
        pollInterval: Duration = .milliseconds(100),
        loadWait: Duration = .seconds(3),
        answerLifetime: Duration = .seconds(TypedGrammarRequest.maximumAge)
    ) {
        self.store = store
        self.isEnabled = isEnabled
        self.correct = correct
        self.now = now
        self.pollInterval = pollInterval
        self.loadWait = loadWait
        self.answerLifetime = answerLifetime
    }

    /// Starts listening. A question left over from before this process — the
    /// app ended before it answered — is removed rather than answered late.
    func start() {
        guard observation == nil else { return }
        store.clearTypedGrammarExchange()
        observation = VocaPhoneDarwinCenter.observe(.typedGrammarRequested, queue: queue) { [weak self] in
            self?.answerPendingRequest()
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }

    /// Reads the question, if one is waiting, and answers it. Runs on this
    /// object's own queue, so a check never blocks the main thread or another
    /// check; called directly by tests.
    func answerPendingRequest() {
        guard let request = store.takeTypedGrammarRequest() else { return }
        guard request.isFresh(at: now()) else { return }
        guard isEnabled(), let first = request.sentences.first else {
            reply(TypedGrammarAnswer(id: request.id, corrected: request.sentences.map { _ in nil }))
            return
        }
        let keep = Set(request.keep)
        let thorough = request.thorough ?? false
        var opening = correct(first, keep, thorough)
        // Nil means the model was not loaded and asking started the load,
        // which takes a few hundred milliseconds. Worth waiting for: the
        // user has paused, and the next pause may be a long way off.
        var waited: Duration = .zero
        while opening == nil, waited < loadWait {
            Thread.sleep(forTimeInterval: Self.seconds(pollInterval))
            waited += pollInterval
            opening = correct(first, keep, thorough)
        }
        var corrected: [String?] = [opening]
        for sentence in request.sentences.dropFirst() {
            // The keyboard gives up on a question this old and asks again.
            guard request.isFresh(at: now()) else { return }
            corrected.append(opening == nil ? nil : correct(sentence, keep, thorough))
        }
        // An answer now would only leave the sentences on disk.
        guard request.isFresh(at: now()) else { return }
        reply(TypedGrammarAnswer(id: request.id, corrected: corrected))
    }

    private func reply(_ answer: TypedGrammarAnswer) {
        guard (try? store.saveTypedGrammarAnswer(answer)) != nil else { return }
        // On this queue, where every answer is written, so the check-then-
        // delete cannot remove a newer one.
        queue.asyncAfter(deadline: .now() + Self.seconds(answerLifetime)) { [store] in
            store.removeTypedGrammarAnswer(id: answer.id)
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
