import Foundation

/// Learns the spellings the user fixes in a dictation this keyboard typed
/// (`CorrectionWatch`), without adding work to a keystroke.
///
/// The keyboard already reads the text around the cursor once per change
/// (`handleTextChange`). For a short while after a dictation that snapshot
/// is handed here too; the comparison runs in order on a utility queue,
/// never on the main thread that draws the keys. `finish()` — the next
/// dictation, the keyboard going away, another field, or `watchSeconds` —
/// passes what was learned, the "heard → corrected" pairs alone, to the app
/// through the App Group (`LearnedCorrectionBatch`). No text from the field
/// is written anywhere.
///
/// Call it from the main thread. The watch itself lives on `queue` only.
final class DictationCorrectionObserver: @unchecked Sendable {
    /// Longest a dictation is followed, as VocaMac does.
    static let watchSeconds: TimeInterval = 20

    private let queue = DispatchQueue(label: "com.vocahq.vocaphone.keyboard.corrections", qos: .utility)
    private let deliver: @Sendable ([LearnedCorrection]) -> Void
    /// Confined to `queue`.
    private var watch: CorrectionWatch?
    /// Main thread.
    private(set) var isActive = false
    private var deadline: DispatchWorkItem?

    init(deliver: @escaping @Sendable ([LearnedCorrection]) -> Void = { DictationCorrectionObserver.handToApp($0) }) {
        self.deliver = deliver
    }

    /// A dictation was just typed, between `before` and `after` as they read
    /// just before it. Finishes the one before it, then follows this one.
    func dictationInserted(_ inserted: String, before: String, after: String, wordList: TypingWordList) {
        finish()
        isActive = true
        queue.async { [self] in
            let watch = CorrectionWatch { wordList.contains($0) }
            guard watch.start(inserted) else { return }
            // The baseline: the field as the insertion left it.
            watch.read(before: before + inserted, after: after)
            self.watch = watch.isActive ? watch : nil
        }
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchSeconds, execute: work)
    }

    /// The keyboard's snapshot of the text around the cursor, after a change.
    /// Nil sides are iOS not answering, which says nothing.
    func fieldRead(before: String?, after: String?) {
        guard isActive, let before, let after else { return }
        queue.async { [self] in watch?.read(before: before, after: after) }
    }

    /// Stops following the dictation and hands over what it taught.
    func finish() {
        guard isActive else { return }
        isActive = false
        deadline?.cancel()
        deadline = nil
        queue.async { [self] in
            let found = watch?.finish() ?? []
            watch = nil
            if !found.isEmpty { deliver(found) }
        }
    }

    /// Waits for the queue; tests only.
    func drain() {
        queue.sync {}
    }

    static func handToApp(_ found: [LearnedCorrection]) {
        try? SharedStore.shared.saveLearnedCorrections(LearnedCorrectionBatch(corrections: found))
    }
}
