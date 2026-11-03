package com.vocahq.vocaphone.core

import kotlin.math.exp

/**
 * Which words a speech engine was unsure of, for the one question
 * [VocabularyCorrection] asks: may these ordinary words be a custom word the
 * engine misheard? "cooper netties" is two real words, and only an engine that
 * was unsure of them is evidence that the speaker said "Kubernetes". Mirrors
 * `RecognitionConfidence.swift`.
 *
 * Engines that report a confidence:
 *
 * - whisper.cpp: each token's probability, which decoding computes anyway
 *   (`WhisperLib.getTokenConfidence`). A word is the geometric mean of its
 *   tokens, which is what WhisperKit's word timings report on iOS. Token
 *   timestamps are not turned on for it.
 *
 * Every other engine reports nothing — the prebuilt sherpa-onnx JNI's result
 * carries no log probabilities — which is not the same as being sure:
 * [lowConfidenceWords] is null then, and a run of real words is left alone.
 */
class RecognitionConfidence private constructor(
    private val unsure: Set<String>,
    private val sure: Set<String>,
    /** Whether any word carried a probability. */
    val isReported: Boolean,
) {
    /** How a word's probability is made from its tokens'. */
    enum class WordScore {
        /** exp(mean log probability): WhisperKit's word probability. */
        GEOMETRIC_MEAN,

        /** The least sure token. */
        MINIMUM,
    }

    /**
     * One decoded token: its text as the engine writes it, a leading space (or
     * "▁") starting a new word, and its natural-log probability.
     */
    data class Token(val text: String, val logProbability: Float)

    /**
     * This confidence with one more decoded word. A word the engine gave no
     * probability counts as sure. A word hyphenated or joined by punctuation is
     * recorded as the words [VocabularyCorrection] will see.
     */
    fun add(word: String, probability: Double?): RecognitionConfidence {
        val unsure = unsure.toHashSet()
        val sure = sure.toHashSet()
        for (part in VocabularyCorrection.words(word)) {
            if (part.key.isEmpty()) continue
            if (probability != null && probability < LOW_THRESHOLD) unsure += part.key else sure += part.key
        }
        return RecognitionConfidence(unsure, sure, isReported || probability != null)
    }

    /**
     * Both decodes' words, as though decoded together: a long recording's
     * windows, or a chunk's two halves.
     */
    fun merging(other: RecognitionConfidence): RecognitionConfidence =
        RecognitionConfidence(unsure + other.unsure, sure + other.sure, isReported || other.isReported)

    /**
     * Words ([VocabularyCorrection.key]s) decoded below [LOW_THRESHOLD] every
     * time they were heard, or null when the engine reported nothing.
     *
     * The text correction sees has been repaired and styled since the decode,
     * so a word's position there no longer matches the engine's. A word heard
     * once unsure and once sure ("pie" twice) is therefore left out: one unsure
     * occurrence must never vouch for respelling another the engine was sure of.
     */
    val lowConfidenceWords: Set<String>?
        get() = if (isReported) unsure - sure else null

    override fun equals(other: Any?): Boolean =
        other is RecognitionConfidence && unsure == other.unsure && sure == other.sure &&
            isReported == other.isReported

    override fun hashCode(): Int = (unsure.hashCode() * 31 + sure.hashCode()) * 31 + isReported.hashCode()

    override fun toString(): String = "RecognitionConfidence(lowConfidenceWords=$lowConfidenceWords)"

    companion object {
        /**
         * Below this a word counts as unsure. Whisper's probability for a
         * clearly spoken common word is usually above 0.9; misheard names and
         * jargon fall well below it. VocaMac's threshold.
         */
        const val LOW_THRESHOLD = 0.6

        val UNREPORTED = RecognitionConfidence(emptySet(), emptySet(), false)

        /** Words built from [tokens] as [score] says. */
        fun fromTokens(tokens: List<Token>, score: WordScore): RecognitionConfidence {
            val texts = mutableListOf<StringBuilder>()
            val logProbabilities = mutableListOf<MutableList<Float>>()
            for (token in tokens) {
                if (texts.isEmpty() || startsWord(token.text)) {
                    texts += StringBuilder(token.text)
                    logProbabilities += mutableListOf(token.logProbability)
                } else {
                    texts.last().append(token.text)
                    logProbabilities.last() += token.logProbability
                }
            }
            var confidence = UNREPORTED
            for (index in texts.indices) {
                confidence = confidence.add(texts[index].toString(), probability(logProbabilities[index], score))
            }
            return confidence
        }

        /**
         * Tokens written by a native bridge one per line, as
         * `<log probability>\t<token text>`. Lines that do not parse are skipped.
         */
        fun fromTokenLines(text: String, score: WordScore): RecognitionConfidence {
            val tokens = text.split('\n').mapNotNull { line ->
                val tab = line.indexOf('\t')
                if (tab < 0) return@mapNotNull null
                val value = line.substring(0, tab).toFloatOrNull()?.takeIf { it.isFinite() }
                    ?: return@mapNotNull null
                Token(line.substring(tab + 1), value)
            }
            return fromTokens(tokens, score)
        }

        /** A leading space, or SentencePiece's "▁" where an engine passes it on. */
        private fun startsWord(token: String): Boolean {
            val first = token.firstOrNull() ?: return false
            return first.isWhitespace() || first == '▁'
        }

        private fun probability(logProbabilities: List<Float>, score: WordScore): Double = when (score) {
            WordScore.GEOMETRIC_MEAN -> exp(logProbabilities.sum().toDouble() / logProbabilities.size)
            WordScore.MINIMUM -> exp((logProbabilities.minOrNull() ?: 0f).toDouble())
        }
    }
}
