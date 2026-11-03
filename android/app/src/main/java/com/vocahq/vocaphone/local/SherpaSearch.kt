package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.RecognitionHints
import com.vocahq.vocaphone.core.TranscriptionQuality

/**
 * How a sherpa-onnx recognizer searches: its decoding method and beam width,
 * and whether it takes the user's words as transducer hotwords. All of it is
 * fixed when the recognizer is built. Mirrors `SherpaSearch.swift` on iOS.
 *
 * Two shapes only. The usual one is the family's own: greedy for every family
 * the app ships (see [SherpaFamily.supportsBeamSearch]). The other is beam
 * search with a BPE vocabulary, for a model with a
 * [LocalModelDescriptor.hotwordVocabularyFile] while the user has custom words.
 * Without words there is nothing to boost and the beam would only cost time,
 * so a user without a vocabulary keeps greedy search, and one who adds or
 * clears it gets the recognizer rebuilt once, never two held at once.
 */
internal data class SherpaSearch(
    val decodingMethod: String,
    val maxActivePaths: Int,
    /** The BPE vocabulary's path, empty unless this search takes hotwords. */
    val bpeVocabulary: String = "",
    /** Ignored unless [takesHotwords]. */
    val hotwordScore: Float = 0f,
) {
    val takesHotwords: Boolean get() = bpeVocabulary.isNotEmpty()

    /** The `modelingUnit` sherpa-onnx splits hotwords with: BPE, or its default. */
    val modelingUnit: String get() = if (takesHotwords) "bpe" else ""

    companion object {
        const val BEAM_SEARCH = "modified_beam_search"

        /**
         * [vocabulary] is the bundled hotword vocabulary's path when the
         * dictation has hotwords for it, and null otherwise. Only the NeMo
         * transducer can use one; every other family keeps its own method,
         * because a beam search it does not support ends the process.
         */
        fun of(family: SherpaFamily, quality: TranscriptionQuality, vocabulary: String?): SherpaSearch =
            if (family == SherpaFamily.NEMO_TRANSDUCER && !vocabulary.isNullOrEmpty()) {
                SherpaSearch(
                    decodingMethod = BEAM_SEARCH,
                    maxActivePaths = RecognitionHints.TRANSDUCER_BEAM_WIDTH,
                    bpeVocabulary = vocabulary,
                    hotwordScore = RecognitionHints.TRANSDUCER_HOTWORD_SCORE,
                )
            } else {
                SherpaSearch(
                    decodingMethod = family.decodingMethod(quality),
                    maxActivePaths = quality.sherpaMaxActivePaths,
                )
            }
    }
}

/**
 * Whether a decode with transducer hotwords stopped before the speech did.
 * Mirrors `SherpaHotwordCheck` in `SherpaSearch.swift`.
 *
 * sherpa-onnx 1.13.8's NeMo beam search boosts a hotword's pieces as they are
 * emitted and takes the bonus back only if a later piece leaves the hotword. A
 * hypothesis that has emitted part of a hotword can therefore keep its bonus by
 * emitting nothing at all, and it then outscores every hypothesis that goes on
 * transcribing: "add a quart of strong consom and let all continue boiling"
 * came back as "add a quart of strong Conflue" with Confluence among 56
 * hotwords. What it leaves is audible speech after the last token, and that is
 * what this looks for: a stretch at least [MINIMUM_TAIL_SECONDS] long,
 * starting [MARGIN_SECONDS] after the last token began, whose loudest frame is
 * at least [LOUDNESS_RATIO] of the window's. A window that trips it is decoded
 * again without hotwords; trailing silence, the usual end of a dictation, does
 * not.
 *
 * The same search can also loop on a hotword it has just finished, typing
 * "tell Aoife on Slack Slack Slack" where the speaker said Slack once
 * (`vocab-en`, one clip in 50 at score 2.0). [repeatsAHotword] catches that,
 * and the window is decoded again without hotwords too.
 */
internal object SherpaHotwordCheck {
    const val MARGIN_SECONDS = 0.5
    const val MINIMUM_TAIL_SECONDS = 1.0
    const val LOUDNESS_RATIO = 0.25

    /**
     * [lastTokenSeconds] is when the last token began, or null when the decode
     * produced none, which makes the whole window the tail.
     */
    fun stoppedEarly(samples: FloatArray, lastTokenSeconds: Double?): Boolean {
        val loudest = SherpaLongAudio.loudestFrame(samples)
        if (SherpaLongAudio.isEffectivelySilent(loudest)) return false
        val rate = SherpaLongAudio.SAMPLE_RATE.toDouble()
        val start = lastTokenSeconds?.let { ((maxOf(it, 0.0) + MARGIN_SECONDS) * rate).toInt() } ?: 0
        if (samples.size - start < (MINIMUM_TAIL_SECONDS * rate).toInt()) return false
        val tail = samples.copyOfRange(start, samples.size)
        return SherpaLongAudio.loudestFrame(tail) >= LOUDNESS_RATIO * loudest
    }

    /**
     * Whether [text] says one of [hotwords] ("/"-separated, as
     * `RecognitionHints.transducerHotwords` writes them) twice in a row.
     */
    fun repeatsAHotword(text: String, hotwords: String): Boolean {
        val spoken = words(text)
        for (phrase in hotwords.split('/')) {
            val target = words(phrase)
            val length = target.size
            if (length == 0 || spoken.size < 2 * length) continue
            for (start in 0..spoken.size - 2 * length) {
                if (spoken.subList(start, start + length) == target &&
                    spoken.subList(start + length, start + 2 * length) == target
                ) {
                    return true
                }
            }
        }
        return false
    }

    /**
     * Case-folded: the decoder's casing of a repeat is its own ("Slack
     * slack"), and the user's list may be lower case.
     */
    private fun words(text: String): List<String> {
        val words = mutableListOf<String>()
        val current = StringBuilder()
        for (character in text) {
            if (character.isLetterOrDigit()) {
                current.append(character.lowercaseChar())
            } else if (current.isNotEmpty()) {
                words.add(current.toString())
                current.clear()
            }
        }
        if (current.isNotEmpty()) words.add(current.toString())
        return words
    }
}
