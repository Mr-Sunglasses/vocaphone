package com.vocahq.vocaphone.core

import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.SherpaFamily
import java.util.Locale

/**
 * The words a dictation's speech model is told to listen for, and the form
 * each engine takes them in. Mirrors `RecognitionHints.swift` on iOS.
 *
 * One list serves every engine. [terms] builds it in ascending order of
 * importance: terms from the text around the cursor first, then the targets of
 * the user's replacements, then the user's own vocabulary, so every engine
 * that has to shorten it cuts from the front and the user's own words are the
 * last to go. Within each source the term its caller ranks first ends up last,
 * so the cut takes a source's least important term first. Today only the
 * vocabulary is filled in; the other two sources are where replacements and
 * on-screen terms will join it.
 *
 * What an engine keeps it writes most important first, which for the
 * vocabulary alone is the order the user wrote it: the order the prompt has
 * always had. Order is not free. On `tools/asr-bench`'s `vocab-en` set,
 * writing the same terms reversed moved Whisper's term accuracy by as much as
 * switching the framing did.
 *
 * Engines take the list as:
 *
 * - Whisper (whisper.cpp here, WhisperKit on iOS): a comma-separated prompt
 *   that conditions the decoder, [whisperPrompt].
 * - Qwen3-ASR: comma-separated hotwords in its chat prompt, [qwen3Hotwords].
 * - Parakeet Unified: hotwords its transducer's beam search boosts while it
 *   decodes, [transducerHotwords]. sherpa-onnx 1.13.8 biases a transducer only
 *   through beam search and a BPE vocabulary, which the app bundles for this
 *   one model ([LocalModelDescriptor.hotwordVocabularyFile]).
 * - Every other sherpa-onnx family: nothing. The other Parakeets are TDT
 *   models, whose beam search on 1.13.8 can drop whole sentences, and the CTC
 *   and non-autoregressive families condition on audio alone.
 *
 * Every engine still gets [VocabularyCorrection] afterwards, which spells close
 * misses the user's way from the whole vocabulary, whatever was cut here.
 */
object RecognitionHints {

    /**
     * The whole list's length, in characters, with ", " between terms. It
     * bounds the context terms only: the user's own words are never dropped
     * here, only by an engine's own budget.
     */
    const val MAX_CHARACTERS = 2_000

    /** Most terms taken from the text around the cursor. */
    const val MAX_CONTEXT_TERMS = 100

    /**
     * The ordered, deduplicated hint list. Least important first.
     *
     * Each argument lists its most important term first: [vocabulary] in the
     * order the user wrote it, [contextTerms] as the extractor ranked them.
     * Duplicates are compared case-insensitively, and the user's spelling wins
     * over a replacement's or the screen's, because the point of the list is
     * that the user's capitalization is the correct one.
     */
    fun terms(
        vocabulary: List<String>,
        replacementTargets: List<String> = emptyList(),
        contextTerms: List<String> = emptyList(),
    ): List<String> {
        val seen = mutableSetOf<String>()
        val user = vocabulary.filter { seen.add(it.lowercase(Locale.ROOT)) }
        val targets = replacementTargets
            .map { it.trim() }
            .filter { isHintableReplacement(it) && seen.add(it.lowercase(Locale.ROOT)) }
        val kept = (targets + user).joinToString(", ").length
        val context = mutableListOf<String>()
        var used = 0
        for (term in contextTerms) {
            val trimmed = term.trim()
            if (trimmed.isEmpty() || trimmed.lowercase(Locale.ROOT) in seen) continue
            if (context.size >= MAX_CONTEXT_TERMS || kept + used + trimmed.length + 2 > MAX_CHARACTERS) break
            seen.add(trimmed.lowercase(Locale.ROOT))
            context.add(trimmed)
            used += trimmed.length + 2
        }
        return context.reversed() + targets.reversed() + user.reversed()
    }

    /**
     * A replacement's target that reads like a term rather than a snippet.
     *
     * "get hub" → "GitHub" makes GitHub worth listening for. A replacement that
     * types an email address, a link or a sentence is not a word anyone says.
     */
    fun isHintableReplacement(text: String): Boolean {
        val trimmed = text.trim()
        if (trimmed.length !in 2..32 || trimmed.none(Char::isLetter)) return false
        if ('@' in trimmed || '/' in trimmed || ':' in trimmed) return false
        return trimmed.split(Regex("\\s+")).size <= 3
    }

    /**
     * The prompt competes with the audio for the decoder's context window, and
     * a long one measurably degrades transcription of everything the user did
     * say. whisper.cpp keeps only the last half of its 448-token text context
     * for a prompt anyway; stopping well short of it keeps the context spent on
     * speech.
     */
    const val WHISPER_PROMPT_CHARACTERS = 640

    /**
     * The Whisper prompt for [terms]: the terms, comma separated, ending in a
     * full stop, dropping terms from the front until it fits
     * [WHISPER_PROMPT_CHARACTERS]. Empty when nothing fits.
     *
     * A bare list, which is what OpenAI documents for vocabulary biasing and
     * reads to the decoder as a plausible run of text in the same domain as the
     * speech. A "Glossary: " framing (VocaMac's) was measured against it on
     * `tools/asr-bench`'s `vocab-en` set and was no better: one term in 120
     * worse on each platform in this order, a tie across two orders on
     * Android. See docs/local-model-review.md.
     *
     * Whole terms only: half a name is worse than no name, because it biases
     * toward a spelling nobody wants. The front of [terms] is where the least
     * important are (see [terms]); the terms kept are written most important
     * first.
     */
    fun whisperPrompt(terms: List<String>): String {
        // Most important first, until the next term would pass the budget.
        // That stops after a few dozen terms however long the list, where
        // rebuilding every shorter list did work that grew with the square of
        // a pasted vocabulary.
        val kept = StringBuilder()
        for (term in terms.asReversed()) {
            val separator = if (kept.isEmpty()) "" else ", "
            // + 1 for the closing full stop.
            if (kept.length + separator.length + term.length + 1 > WHISPER_PROMPT_CHARACTERS) break
            kept.append(separator).append(term)
        }
        return if (kept.isEmpty()) "" else "$kept."
    }

    /**
     * Whether a prompted decode that came back empty should be decoded again
     * without the prompt.
     *
     * A vocabulary prompt can talk Whisper out of the speech altogether: the
     * decoder opens on end-of-text and the dictation fails as "no speech". The
     * same audio without the prompt is the dictation the user would have had
     * with no vocabulary, which beats nothing.
     */
    fun shouldRetryWithoutPrompt(text: String, prompt: String): Boolean =
        prompt.isNotEmpty() && text.isBlank()

    /**
     * Most hotwords Qwen3-ASR is given, and their combined length.
     *
     * sherpa-onnx writes them into the system turn of Qwen3-ASR's chat prompt,
     * which shares a 512-token window with the audio and the transcript. The
     * app's longest window is 14 seconds, about 180 audio tokens, and up to 256
     * transcript tokens for Hindi; 200 characters of names is about 50 tokens
     * more, which still fits.
     */
    const val MAX_HOTWORDS = 20
    const val MAX_HOTWORD_CHARACTERS = 200

    /**
     * Qwen3-ASR's hotwords: the terms at the end of [terms], most important
     * first and comma separated, as sherpa-onnx's `hotwords` stream option
     * takes them. Null when there are none.
     *
     * The option is split on ASCII commas, so a comma inside a term becomes a
     * space.
     */
    fun qwen3Hotwords(terms: List<String>): String? {
        val kept = mutableListOf<String>()
        var used = 0
        for (raw in terms.asReversed()) {
            val term = raw.replace(',', ' ').trim()
            if (term.isEmpty()) continue
            if (kept.size >= MAX_HOTWORDS || used + term.length + 1 > MAX_HOTWORD_CHARACTERS) break
            kept.add(term)
            used += term.length + 1
        }
        return if (kept.isEmpty()) null else kept.joinToString(",")
    }

    /**
     * Most hotwords a transducer is given.
     *
     * sherpa-onnx builds them into a small prefix tree once per decode, so the
     * count costs next to nothing; what grows with it is the chance that some
     * boosted spelling fits a stretch of ordinary speech. `vocab-en` clips
     * carry six or so terms, and LibriSpeech was measured with all 56 of its
     * terms boosted at once (docs/local-model-review.md); this leaves a user a
     * little more than that.
     */
    const val MAX_TRANSDUCER_HOTWORDS = 64

    /**
     * How strongly each word piece of a hotword is boosted, in log
     * probability, and how many hypotheses the beam search keeps. Tuned on
     * `tools/asr-bench`'s `vocab-en` set with LibriSpeech as the check that
     * ordinary speech is not respelled; see docs/local-model-review.md.
     */
    const val TRANSDUCER_HOTWORD_SCORE = 2.0f
    const val TRANSDUCER_BEAM_WIDTH = 4

    /**
     * A transducer's hotwords: the terms at the end of [terms], most important
     * first, one phrase each, separated by "/" as sherpa-onnx's per-stream
     * hotwords take them. Null when there are none.
     *
     * sherpa-onnx reads "/" as the phrase separator and a word that starts with
     * ":" as a score, and its token lookup reads a word piece starting with "#"
     * or "@" as a threshold or a label. Measured on 1.13.8, the term
     * "foo :bar" throws inside sherpa-onnx, which through JNI is a crash, and
     * "Kanishk #x" cut most of a sentence out of the transcript. None of the
     * four can be part of a hotword, so each becomes a space, which splits the
     * term into words the way the speaker would say them.
     */
    fun transducerHotwords(terms: List<String>): String? {
        val kept = mutableListOf<String>()
        for (term in terms.asReversed()) {
            val cleaned = term.map { if (it in "/:#@" || it.isWhitespace()) ' ' else it }.joinToString("")
            val phrase = cleaned.split(' ').filter { it.isNotEmpty() }.joinToString(" ")
            if (phrase.isEmpty()) continue
            if (kept.size >= MAX_TRANSDUCER_HOTWORDS) break
            kept.add(phrase)
        }
        return if (kept.isEmpty()) null else kept.joinToString("/")
    }

    /**
     * The hotwords a sherpa-onnx recognizer for [model] decodes with, or null
     * for a model that takes none.
     *
     * Qwen3-ASR's are set as a stream option. A transducer's go through
     * `OfflineRecognizer.createStream(hotwords)`, and only on a recognizer
     * built for them (see [com.vocahq.vocaphone.local.SherpaSearch]): every
     * other family answers that call by exiting the process.
     */
    fun sherpaHotwords(model: LocalModelDescriptor, terms: List<String>): String? = when {
        model.hotwordVocabularyFile != null -> transducerHotwords(terms)
        model.sherpaFamily == SherpaFamily.QWEN3_ASR -> qwen3Hotwords(terms)
        else -> null
    }
}
