package com.vocahq.vocaphone.core

/**
 * The optional "Fix grammar (English)" stage, as [DictatedTranscript] sees it.
 *
 * An interface rather than the corrector itself so that `core/` stays free of
 * ONNX Runtime: the app passes [com.vocahq.vocaphone.grammar.GrammarCorrector],
 * tests pass a lambda. An implementation must return its input unchanged
 * whenever it cannot do better — a missing model, a runtime error, or running
 * out of time — and must never change a word in [keep].
 */
fun interface GrammarStage {
    fun correct(text: String, keep: Set<String>): String
}
