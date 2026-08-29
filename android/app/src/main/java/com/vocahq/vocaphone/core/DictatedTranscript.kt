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
 *
 * Mirrors the iOS client's `DictatedTranscript`, minus the digits step, which
 * only that platform has.
 */
object DictatedTranscript {
    fun finished(
        raw: String?,
        style: WritingStyle,
        language: String = "auto",
        styledUpstream: Boolean = false,
        repairSpeech: Boolean,
    ): String {
        val cleaned = TranscriptSanitizer.clean(raw)
        val repaired = if (repairSpeech && style != WritingStyle.RAW) {
            TranscriptRepair.apply(cleaned, language)
        } else {
            cleaned
        }
        return if (styledUpstream) repaired else TranscriptStyler.apply(repaired, style, language)
    }
}
