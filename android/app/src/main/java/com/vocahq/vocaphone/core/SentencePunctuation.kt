package com.vocahq.vocaphone.core

/**
 * The marks a script closes a sentence with, and the rule for deciding which
 * script a transcript is written in.
 *
 * Shared by [TranscriptRepair], which *inserts* marks, and [TranscriptStyler],
 * which formats around marks that are already there. Two copies of this table
 * would drift, and the visible failure is a Hindi transcript that one stage
 * ends with a danda and the other with a full stop.
 */
data class SentencePunctuation(
    val terminator: String,
    val separator: String,
    val exclamation: String,
    val question: String,
    /**
     * Every mark that can close a sentence: this script's, plus the ones a
     * model borrows from other scripts often enough to matter.
     */
    val terminators: String,
    /**
     * What sits between two sentences. Empty for the scripts that do not put a
     * space after their punctuation.
     */
    val join: String,
) {
    /**
     * Whether sentences here are built the way English builds them — a full
     * stop, a following space, a capital. [TranscriptRepair]'s inference rules
     * are written against English and are a no-op in any other Latin language,
     * but a script that spaces or terminates differently would be damaged by
     * them.
     */
    val usesLatinLayout: Boolean get() = join == " " && terminator == "."

    companion object {
        /** Marks that never take a space before them and always take one after. */
        const val UNIVERSAL_TERMINATORS = ".!?。！？।۔။។།؟"

        /** Marks that separate parts of a sentence rather than ending one. */
        const val UNIVERSAL_SEPARATORS = ",;:،、၊"

        /**
         * Every character the repair stage treats as punctuation, in any
         * script. One list rather than a per-rule literal, because a rule that
         * inserts a mark and a rule that spaces around one disagreeing about
         * what a mark *is* is invisible until a transcript in that script comes
         * out wrong. Contains no character-class metacharacter, so it can be
         * interpolated into a `[...]` on both platforms and produce the same
         * class.
         */
        const val UNIVERSAL_MARKS = "$UNIVERSAL_TERMINATORS$UNIVERSAL_SEPARATORS…"

        val LATIN = SentencePunctuation(".", ",", "!", "?", ".!?", " ")
        val CJK = SentencePunctuation("。", "、", "！", "？", "。！？.!?", "")
        val ARABIC = SentencePunctuation(".", "،", "!", "؟", ".!?؟", " ")
        val URDU = SentencePunctuation("۔", "،", "!", "؟", "۔.!?؟", " ")
        val DANDA = SentencePunctuation("।", ",", "!", "?", "।.!?", " ")

        /**
         * Scripts written with a full stop rather than the danda their
         * neighbours use. Still accepts a danda on input, because a
         * multilingual model emits one for Tamil often enough.
         */
        val INDIC_LATIN = SentencePunctuation(".", ",", "!", "?", "।.!?", " ")

        /** Thai and Lao close a sentence with a space, not a mark. */
        val UNTERMINATED = SentencePunctuation("", " ", "!", "?", "!?", " ")
        val BURMESE = SentencePunctuation("။", "၊", "!", "?", "။.!?", " ")
        val KHMER = SentencePunctuation("។", ",", "!", "?", "។.!?", " ")
        val TIBETAN = SentencePunctuation("།", "།", "!", "?", "།.!?", " ")

        /**
         * The profile for [language], falling back to what the text itself is
         * written in when the engine reported nothing (Automatic).
         */
        fun resolve(language: String, text: String): SentencePunctuation {
            val base = when (language.lowercase().substringBefore('-')) {
                "ja", "zh", "yue" -> CJK
                "ar", "fa", "ps" -> ARABIC
                "ur", "sd", "ks" -> URDU
                "hi", "mr", "ne", "bn", "as", "pa" -> DANDA
                "ta", "te", "kn", "ml", "gu", "si" -> INDIC_LATIN
                "th", "lo" -> UNTERMINATED
                "my" -> BURMESE
                "km" -> KHMER
                "bo" -> TIBETAN
                else -> when {
                    text.any { it in "。、！？" } -> CJK
                    text.any { it in "،؟" } -> ARABIC
                    text.contains('۔') -> URDU
                    text.contains('।') || containsDandaScript(text) -> DANDA
                    else -> LATIN
                }
            }
            val merged = StringBuilder()
            for (character in UNIVERSAL_TERMINATORS + base.terminators) {
                if (character !in merged) merged.append(character)
            }
            return base.copy(terminators = merged.toString())
        }

        /**
         * Devanagari, Bengali/Assamese, and Gurmukhi conventionally use the
         * danda. This is the fallback when Automatic was selected and the
         * engine did not expose the language it detected.
         */
        fun containsDandaScript(text: String): Boolean = text.any { character ->
            character.code in 0x0900..0x097F ||
                character.code in 0x0980..0x09FF ||
                character.code in 0x0A00..0x0A7F
        }
    }
}
