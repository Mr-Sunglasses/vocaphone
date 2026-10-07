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
 * 2. Repair — the one stage allowed to change the words, and only when the user
 *    has left Clean up speech on. It runs before styling because it is what
 *    puts the sentence boundaries *there*: styling capitalizes and terminates
 *    around boundaries, and cannot find one that is missing. Never for `RAW`,
 *    which promises the model's own output.
 * 3. Style — but only for transcripts produced on this device. A gateway has
 *    already applied the writing style the session asked for, and applying it
 *    twice is how "Hello." becomes "Hello.." on one route and not the other.
 * 4. Custom vocabulary — after styling, so the user's own capitalization of a
 *    name is the last word on it; before spoken emoji and digits. Every route,
 *    because only Whisper can be prompted with the list. Never for `RAW`.
 *    One-letter slips are corrected only in English text; other languages get
 *    spacing and case.
 * 5. Spoken emoji — after styling, because the styler has to see "emoji" as an
 *    ordinary word to capitalize and terminate around it; before digits,
 *    because the table's keys are words — "hundred emoji" is 💯, and once
 *    digit conversion has made it "100 emoji" there is no key left to find.
 *    Applies whichever route produced the transcript: unlike styling, no
 *    gateway has done it already.
 * 6. Digits — after styling, so sentence capitalization can still see the
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
        snippets: List<Snippet> = emptyList(),
        vocabulary: List<String> = emptyList(),
        isDictionaryWord: (String) -> Boolean = { false },
    ): String {
        val cleaned = TranscriptSanitizer.clean(raw)
        val repaired = if (repairSpeech && style != WritingStyle.RAW) {
            TranscriptRepair.apply(cleaned, language)
        } else {
            cleaned
        }
        val styled = if (styledUpstream) repaired else TranscriptStyler.apply(repaired, style, language)
        // Never for RAW, on the same grounds as repair: raw promises the
        // model's own output, and a glyph is not something the model said.
        val spelled = if (style != WritingStyle.RAW) {
            // A trigger corrected into a term would never expand. Found by the
            // expander's own pattern, so exactly what it will match.
            VocabularyCorrection.apply(
                styled,
                vocabulary,
                isDictionaryWord,
                SnippetExpander.triggerRanges(styled, snippets),
                // The word list that keeps a real word from being taken for a
                // near miss is English; in any other language nothing would.
                nearMisses = vocabulary.isNotEmpty() &&
                    TranscriptRepair.isEnglish(styled, language, isDictionaryWord),
            )
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
}
