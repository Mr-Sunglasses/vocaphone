import Foundation

/// The optional "Fix grammar (English)" stage, as `DictatedTranscript` sees it.
///
/// A protocol rather than the corrector itself, because this file is compiled
/// into the keyboard extension and the corrector needs ONNX Runtime, which only
/// the containing app links. The app passes `GrammarCorrector`; tests pass a
/// stub. An implementation must return its input unchanged whenever it cannot
/// do better — no model, a runtime error, out of time — and must never change
/// a word in `keeping`.
protocol GrammarStage: Sendable {
    func correct(_ text: String, keeping: Set<String>) -> String
}
