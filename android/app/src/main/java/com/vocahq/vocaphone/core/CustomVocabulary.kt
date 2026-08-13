package com.vocahq.vocaphone.core

import java.util.Locale

/**
 * Words a speech model is unlikely to know: names, places, project code names,
 * the jargon of whatever the user actually does.
 *
 * Whisper takes a prompt that conditions the decoder, which is the one place a
 * user can teach it a spelling without retraining anything. The prompt is a
 * bias and not a rule — the model may still write "Kanishk" as "Kanish" — so
 * this exists to improve the odds, not to guarantee a spelling.
 *
 * The stored text is shared with the iOS client's `CustomVocabulary`, so the
 * parsing rules have to match: split on newlines and commas, keep phrases with
 * spaces in them intact.
 */
object CustomVocabulary {

    /**
     * The prompt competes with the audio for the decoder's context window, and
     * a long one measurably degrades transcription of everything the user did
     * say. Whisper truncates past its own limit anyway; stopping well short of
     * it keeps the context spent on speech.
     */
    private const val MAX_PROMPT_CHARACTERS = 640

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

    /**
     * The `initial_prompt` for whisper.cpp, and the text WhisperKit tokenizes
     * into prompt tokens.
     *
     * A bare comma-separated list is what OpenAI documents for vocabulary
     * biasing, and it reads to the decoder as a plausible run of text in the
     * same domain as the speech. Truncation stops at a term boundary: half a
     * name is worse than no name, because it biases toward a spelling nobody
     * wants.
     */
    fun whisperPrompt(raw: String?): String {
        val terms = terms(raw)
        if (terms.isEmpty()) return ""
        val builder = StringBuilder()
        for (term in terms) {
            val separator = if (builder.isEmpty()) "" else ", "
            if (builder.length + separator.length + term.length > MAX_PROMPT_CHARACTERS) break
            builder.append(separator).append(term)
        }
        return if (builder.isEmpty()) "" else "$builder."
    }
}
