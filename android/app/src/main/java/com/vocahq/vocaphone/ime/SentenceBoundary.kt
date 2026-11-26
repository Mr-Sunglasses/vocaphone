package com.vocahq.vocaphone.ime

import java.util.Locale

/**
 * Sentence capitalization that knows an abbreviation from a full stop: "e.g. ",
 * "Mr. ", "vs. " and "3. " all end in a period and none of them ends a
 * sentence. A port of the iOS keyboard's `SentenceBoundary`, with its list.
 */
internal object SentenceBoundary {
    val ABBREVIATIONS: Set<String> = setOf(
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st",
        "e.g", "i.e", "etc", "vs", "approx", "dept", "est",
        "fig", "no", "vol", "p", "pp", "al", "inc", "ltd", "co",
    )

    /**
     * Whether [token], the text since the last space, ends in a period that
     * is not the end of a sentence: an abbreviation, or a list number ("3").
     * Leading opening punctuation is ignored: "(e.g".
     */
    fun isAbbreviation(token: String): Boolean {
        val trimmed = token.trimStart { it in "(\"'[{“‘" }.removeSuffix(".")
        if (trimmed.isEmpty()) return false
        if (trimmed.all(Char::isDigit)) return true
        return trimmed.lowercase(Locale.ROOT) in ABBREVIATIONS
    }

    /** Whether the text before the cursor genuinely ends a sentence (or is empty). */
    fun endsSentence(before: String): Boolean {
        if (before.isEmpty() || before.endsWith("\n")) return true
        if (!(before.endsWith(". ") || before.endsWith("! ") || before.endsWith("? "))) {
            return before.isBlank()
        }
        if (!before.endsWith(". ")) return true
        val beforeStop = before.dropLast(2)
        val token = beforeStop.takeLastWhile { !it.isWhitespace() }
        if (token.isEmpty()) return true
        return !isAbbreviation(token)
    }
}
