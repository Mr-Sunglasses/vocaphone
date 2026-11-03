package com.vocahq.vocaphone.core

/**
 * Everything that happens to a transcript between the model returning it and
 * the record the keyboard inserts from.
 *
 * One funnel rather than three call sites, because the *order* is load-bearing
 * and was previously only implicit:
 *
 * 1. Sanitize. The later stages capitalize sentences and add terminators, and
 *    doing that to `[BLANK_AUDIO]` only makes it look more like something the
 *    user meant to say.
 * 2. Chinese script, when the user picked Traditional. Before every stage
 *    that reads words, so repair, custom vocabulary and snippets all see the
 *    characters the user writes — a custom 軟體 is never compared with the
 *    model's 软件. Every route and every style, `RAW` included: it is a choice
 *    of writing system, not an edit.
 * 3. Repair — the one stage allowed to change the words, and only when the user
 *    has left Clean up speech on. It runs before styling because it is what
 *    puts the sentence boundaries *there*: styling capitalizes and terminates
 *    around boundaries, and cannot find one that is missing. Never for `RAW`,
 *    which promises the model's own output.
 * 4. Grammar — the optional "Fix grammar (English)" model, after repair
 *    because it reads the sentences repair has finished and its model was
 *    trained on punctuated text, and before style so the styler capitalizes
 *    and terminates whatever words it settled on. Only for on-device
 *    transcripts (a gateway has its own pipeline), never for `RAW`, and only
 *    for English. It may not touch a custom vocabulary word or a snippet
 *    trigger; [ProtectedSpans] are masked inside the stage.
 * 5. Style — but only for transcripts produced on this device. A gateway has
 *    already applied the writing style the session asked for, and applying it
 *    twice is how "Hello." becomes "Hello.." on one route and not the other.
 * 6. Custom vocabulary — after styling, so the user's own capitalization of a
 *    name is the last word on it; before spoken emoji and digits. Every route,
 *    because only Whisper can be prompted with the list. Never for `RAW`. The
 *    user's replacements first ("get hub" → "GitHub"), exact and in any
 *    language; then custom words, which leave a replacement's text alone.
 *    One-letter slips and sound-alikes are corrected only in English text;
 *    other languages get spacing and case. `lowConfidenceWords` is what the
 *    engine was unsure of, or null when it does not say ([RecognitionConfidence]).
 * 7. Spoken emoji — after styling, because the styler has to see "emoji" as an
 *    ordinary word to capitalize and terminate around it; before digits,
 *    because the table's keys are words — "hundred emoji" is 💯, and once
 *    digit conversion has made it "100 emoji" there is no key left to find.
 *    Applies whichever route produced the transcript: unlike styling, no
 *    gateway has done it already.
 * 8. Digits — after styling, so sentence capitalization can still see the
 *    first word. Matching snippets are protected so a number-word trigger
 *    still expands literally after digit conversion finishes.
 */
object DictatedTranscript {
    fun finished(
        raw: String?,
        style: WritingStyle,
        language: String = "auto",
        styledUpstream: Boolean = false,
        repairSpeech: Boolean,
        numbersAsDigits: Boolean = false,
        spokenEmoji: Boolean = false,
        chineseScript: ChineseScript = ChineseScript.UNCHANGED,
        snippets: List<Snippet> = emptyList(),
        vocabulary: List<String> = emptyList(),
        replacements: List<WordReplacement> = emptyList(),
        lowConfidenceWords: Set<String>? = null,
        isDictionaryWord: (String) -> Boolean = { false },
        grammar: GrammarStage? = null,
    ): String {
        val cleaned = TraditionalChinese.apply(TranscriptSanitizer.clean(raw), chineseScript, language)
        val repaired = if (repairSpeech && style != WritingStyle.RAW) {
            TranscriptRepair.apply(cleaned, language)
        } else {
            cleaned
        }
        val corrected = if (
            grammar != null && !styledUpstream && style != WritingStyle.RAW &&
            TranscriptRepair.isEnglish(repaired, language, isDictionaryWord)
        ) {
            grammar.correct(repaired, grammarKeeps(vocabulary, snippets))
        } else {
            repaired
        }
        val styled = if (styledUpstream) corrected else TranscriptStyler.apply(corrected, style, language)
        // Never for RAW, on the same grounds as repair: raw promises the
        // model's own output, and a glyph is not something the model said.
        val spelled = if (style != WritingStyle.RAW) {
            spell(styled, language, snippets, vocabulary, replacements, lowConfidenceWords, isDictionaryWord)
        } else {
            styled
        }
        val emojified = if (spokenEmoji && style != WritingStyle.RAW) {
            SpokenEmoji.glyphsIn(spelled, language)
        } else {
            spelled
        }
        if (!numbersAsDigits) return SnippetExpander.expand(emojified, snippets)

        val protected = SnippetExpander.protect(emojified, snippets)
        return protected.restore(SpokenNumbers.digitsIn(protected.text))
    }

    /** Step 6: the user's replacements, then their custom words. */
    internal fun spell(
        text: String,
        language: String,
        snippets: List<Snippet>,
        vocabulary: List<String>,
        replacements: List<WordReplacement>,
        lowConfidenceWords: Set<String>?,
        isDictionaryWord: (String) -> Boolean,
    ): String {
        // A trigger replaced or corrected into a term would never expand.
        // Found by the expander's own pattern, so exactly what it will match.
        val triggers = SnippetExpander.triggerRanges(text, snippets)
        val replaced = WordReplacements.apply(text, replacements, triggers)
        if (vocabulary.isEmpty()) return replaced.text
        val protected = if (replaced.written.isEmpty()) {
            triggers
        } else {
            SnippetExpander.triggerRanges(replaced.text, snippets) + replaced.written
        }
        return VocabularyCorrection.apply(
            replaced.text,
            vocabulary,
            isDictionaryWord,
            protected,
            // The word list that keeps a real word from being taken for a near
            // miss is English; in any other language nothing would.
            nearMisses = TranscriptRepair.isEnglish(replaced.text, language, isDictionaryWord),
            lowConfidenceWords = lowConfidenceWords,
        )
    }

    /**
     * Every word of the user's vocabulary and snippet triggers, which grammar
     * may not change, less the function words of a vocabulary phrase. A keep
     * is a word no check may touch, so "Bank of America" in the vocabulary
     * used to keep "of", and "I should of known" was never fixed again. A
     * one-word term is kept whatever it is: the user asked for that word.
     *
     * A snippet trigger keeps every word: dictation's grammar runs before the
     * snippets expand, and a trigger it changed ("we was" to "we were") would
     * no longer match.
     */
    internal fun grammarKeeps(vocabulary: List<String>, snippets: List<Snippet>): Set<String> {
        val keeps = HashSet<String>()
        for (phrase in vocabulary) {
            val words = keepWords(phrase)
            keeps += if (words.size == 1) words else words.filterNot { it.replace('’', '\'') in PHRASE_FUNCTION_WORDS }
        }
        for (snippet in snippets) keeps += keepWords(snippet.trigger)
        return keeps
    }

    private fun keepWords(phrase: String): List<String> =
        phrase.split(KEEP_SEPARATOR).filter { it.isNotEmpty() }.map { it.lowercase() }

    private val KEEP_SEPARATOR = Regex("[^\\p{L}\\p{N}'’]+")

    /**
     * Words a phrase in the vocabulary does not make the user's own: the small closed classes (articles, prepositions,
     * pronouns, auxiliaries, conjunctions) the rules and the model exist to
     * correct. As `phraseFunctionWords` in ios/VocaPhoneShared/DictatedTranscript.swift.
     */
    internal val PHRASE_FUNCTION_WORDS = setOf(
        "a", "an", "the", "of", "to", "in", "on", "at", "by", "for", "with", "from", "into", "onto",
        "about", "over", "under", "up", "down", "out", "off", "than", "then", "as", "and", "or", "but",
        "nor", "so", "if", "that", "this", "these", "those", "there", "their", "they're", "its", "it's",
        "i", "me", "my", "you", "your", "you're", "he", "him", "his", "she", "her", "it", "we", "us",
        "our", "they", "them", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does",
        "did", "have", "has", "had", "will", "would", "can", "could", "shall", "should", "may", "might",
        "must", "not", "no", "who", "whom", "whose", "which", "what", "when", "where", "how", "why",
    )
}
