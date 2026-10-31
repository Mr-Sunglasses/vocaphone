import Foundation

/// The Writing check screen's two decisions, kept out of the view so they can
/// be tested: whether to check a text at all, and when to stop checking it.
/// Mirrors `writingCheckApplies` and `checkUntilCancelled` in
/// android/.../ui/WritingCheckScreen.kt.
extension WritingCheck {
    /// Whether the Writing check screen checks `text` at all. The rules are
    /// English ones: on French, "dont" would be "corrected" to "don't". The
    /// same test the keyboard makes, with the keyboard's word list as
    /// `isDictionaryWord`.
    static func applies(to text: String, isDictionaryWord: (String) -> Bool = EnglishWords.contains) -> Bool {
        text.contains(where: \.isLetter) && TranscriptRepair.isEnglish(text, isDictionaryWord: isDictionaryWord)
    }

    /// `check`, with a second pass after `retryAfter` if the model was still
    /// loading, that gives up when its task is cancelled: the model is asked
    /// nothing more, the retry never starts, and the answer is nil.
    func checkUntilCancelled(
        _ text: String,
        model: Model?,
        options: Options,
        retryAfter: Duration = .milliseconds(1200)
    ) async -> Report? {
        let asked: Model? = model.map { model in
            { sentence in Task.isCancelled ? nil : model(sentence) }
        }
        var report = check(text, model: asked, options: options)
        if report.modelPending {
            // The model was loading; asking started it. Once more, a moment later.
            try? await Task.sleep(for: retryAfter)
            guard !Task.isCancelled else { return nil }
            report = check(text, model: asked, options: options)
        }
        return Task.isCancelled ? nil : report
    }
}
