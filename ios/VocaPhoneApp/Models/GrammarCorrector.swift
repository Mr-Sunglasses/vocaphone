import Foundation

/// The "Fix grammar (English)" stage: `GrammarTagger` over a `GrammarSession`,
/// fed from the verified files in `GrammarModelStore`.
///
/// Built to fail safe, because dictation must never fail or noticeably slow
/// down for an optional nicety. Every way this can go wrong — no model yet, a
/// damaged file, ONNX Runtime refusing to load, running past the budget —
/// returns the transcript as it was and leaves one content-free line in the
/// diagnostic log. Nothing reaches telemetry.
///
/// Loading costs a few hundred milliseconds (a 1.1 MB tokenizer and a 27 MB
/// session), so it happens off the dictation path: `warm()` is called when a
/// recording starts, and a transcript that finishes before the load does is
/// left alone rather than waited on. Mirrors `GrammarCorrector.kt`.
final class GrammarCorrector: GrammarStage, @unchecked Sendable {
    /// How long the whole stage may take for one transcript.
    static let budget: Duration = .milliseconds(150)

    /// How long one check of typed text may take. Nobody is waiting on an
    /// insertion, so it is longer than dictation's; it still bounds a
    /// paragraph pasted into the field.
    static let typedBudget: Duration = .milliseconds(400)

    struct Loaded {
        let tagger: GrammarTagger
        let close: () -> Void
    }

    typealias Load = @Sendable (URL) throws -> Loaded

    private let directory: @Sendable () -> URL?
    private let isReady: @Sendable () -> Bool
    private let log: @Sendable (DiagnosticEvent) -> Void
    private let load: Load
    private let budgetNanoseconds: UInt64
    private let queue = DispatchQueue(label: "com.vocahq.vocaphone.grammar-load", qos: .userInitiated)
    private let lock = NSLock()
    private var loaded: Loaded?
    private var loading = false
    /// Set after a load failed for these files, so a broken install is not retried per dictation.
    private var failedFor: Date?
    private var hasFailed = false
    /// Bumped by `release()`. A load that started before the release finishes
    /// into a session nobody wants any more, so it is closed instead of kept:
    /// otherwise a release during a warm-up left the session in memory after
    /// the system asked for it back.
    private var generation = 0

    init(
        directory: @escaping @Sendable () -> URL?,
        isReady: @escaping @Sendable () -> Bool,
        log: @escaping @Sendable (DiagnosticEvent) -> Void = { DiagnosticLog.record($0) },
        budget: Duration = GrammarCorrector.budget,
        load: @escaping Load = GrammarCorrector.loadFrom
    ) {
        self.directory = directory
        self.isReady = isReady
        self.log = log
        self.load = load
        let (seconds, attoseconds) = budget.components
        budgetNanoseconds = UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }

    /// Starts loading the model in the background, if it is downloaded and not loaded yet.
    func warm() {
        guard isReady(), let directory = directory() else { return }
        let stamp = Self.stamp(directory)
        let started: Int? = lock.withLock {
            guard loaded == nil, !loading, !(hasFailed && failedFor == stamp) else { return nil }
            loading = true
            return generation
        }
        guard let started else { return }
        queue.async { [self] in
            let result = Result { try load(directory) }
            let stale = lock.withLock { () -> Bool in
                loading = false
                guard started == generation else { return true }
                switch result {
                case let .success(value): loaded = value
                case .failure:
                    hasFailed = true
                    failedFor = stamp
                }
                return false
            }
            if stale {
                if case let .success(value) = result { value.close() }
            } else if case .failure = result {
                log(.grammarLoadFailed)
            }
        }
    }

    func correct(_ text: String, keeping: Set<String>) -> String {
        run(text, keeping: keeping, budget: budgetNanoseconds) ?? text
    }

    /// For "Check grammar while typing": `text` corrected, or `nil` when the
    /// model is not loaded yet, which starts loading it.
    func correctTyped(_ text: String, keeping: Set<String>) -> String? {
        let (seconds, attoseconds) = Self.typedBudget.components
        return run(
            text,
            keeping: keeping,
            budget: UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
        )
    }

    private func run(_ text: String, keeping: Set<String>, budget budgetNanoseconds: UInt64) -> String? {
        guard let current = lock.withLock({ loaded }) else {
            // Not downloaded, not loaded yet, or failed to load: leave it.
            warm()
            return nil
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + budgetNanoseconds
        do {
            let corrected = try current.tagger.correct(text, vocabulary: keeping, deadline: deadline)
            if DispatchTime.now().uptimeNanoseconds > deadline + budgetNanoseconds {
                // One sentence ran far past the budget (the tagger only checks
                // between sentences and passes). Its result is still correct.
                log(.grammarSlow)
            }
            return corrected.contains(where: \.isLetter) ? corrected : text
        } catch {
            log(.grammarFailed)
            return text
        }
    }

    /// Whether a session is loaded and in use. For tests, which otherwise race the loader.
    var isLoaded: Bool { lock.withLock { loaded != nil } }

    /// Frees the session. The next `warm()` loads it again.
    func release() {
        let previous = lock.withLock { () -> Loaded? in
            generation += 1
            defer { loaded = nil }
            return loaded
        }
        previous?.close()
    }

    /// Forgets a failed load, so a fresh download gets its own attempt.
    func modelChanged() {
        lock.withLock { hasFailed = false }
        release()
    }

    private static func stamp(_ directory: URL) -> Date? {
        let model = directory.appendingPathComponent("mindtype_tagger.onnx")
        return (try? FileManager.default.attributesOfItem(atPath: model.path))?[.modificationDate] as? Date
    }

    static let loadFrom: Load = { directory in
        let tokenizer = try ByteLevelBpe.parse(Data(contentsOf: directory.appendingPathComponent("tokenizer.json")))
        let labels = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: directory.appendingPathComponent("labels.json"))
        )
        guard labels.count == GrammarTagger.labelCount, labels.first == "KEEP" else {
            throw GrammarSession.Failure(description: "unexpected labels.json")
        }
        let pairs = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: directory.appendingPathComponent("plausible_pairs.json"))
        )
        let session = try GrammarSession(model: directory.appendingPathComponent("mindtype_tagger.onnx"))
        let tagger = GrammarTagger(tokenizer: tokenizer, labels: labels, plausiblePairs: pairs) { ids, rows in
            try session.run(ids: ids, rows: rows)
        }
        return Loaded(tagger: tagger, close: session.close)
    }
}
