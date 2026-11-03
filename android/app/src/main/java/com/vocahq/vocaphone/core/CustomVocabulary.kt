package com.vocahq.vocaphone.core

import java.util.Locale

/**
 * Words a speech model is unlikely to know: names, places, project code names,
 * the jargon of whatever the user actually does.
 *
 * Whisper takes a prompt that conditions the decoder, and Qwen3-ASR takes
 * hotwords, which is where a user can teach a model a spelling without
 * retraining anything ([RecognitionHints] builds both). Either is a bias and
 * not a rule — the model may still write "Kanishk" as "Kanish" — so this
 * exists to improve the odds, not to guarantee a spelling.
 *
 * The stored text is shared with the iOS client's `CustomVocabulary`, so the
 * parsing rules have to match: split on newlines and commas, keep phrases with
 * spaces in them intact.
 */
object CustomVocabulary {

    /**
     * What a model that cannot take a hint still does with the list: every
     * route spells close matches the user's way ([VocabularyCorrection]), but
     * only Whisper's, Qwen3-ASR's and Parakeet Unified's decoders can be nudged
     * toward the words while they listen
     * ([com.vocahq.vocaphone.local.LocalModelDescriptor.supportsCustomVocabulary]).
     */
    fun spellingOnlyNote(modelName: String?): String? {
        if (modelName.isNullOrBlank()) return null
        return "$modelName cannot be nudged while it decodes, so only close matches are " +
            "corrected. A word it hears as something else entirely stays as it heard it."
    }

    /** Long enough for "Ministry of Electronics and Information Technology". */
    private const val MAX_TERM_CHARACTERS = 64

    /**
     * Distinct terms in the order the user wrote them.
     *
     * Splitting on newlines and commas but not spaces is what lets "Claude
     * Code" stay one phrase. Duplicates are compared case-insensitively while
     * the first spelling is the one kept, because the whole point of the list
     * is that the user's capitalization is the correct one.
     */
    fun terms(raw: String?): List<String> {
        if (raw.isNullOrBlank()) return emptyList()
        val seen = mutableSetOf<String>()
        return raw.split('\n', ',')
            .map { it.trim().take(MAX_TERM_CHARACTERS).trim() }
            .filter { it.isNotEmpty() }
            .filter { seen.add(it.lowercase(Locale.ROOT)) }
    }
}
