package com.vocahq.vocaphone.ime

import java.util.Locale

/**
 * Sentence capitalization that knows an abbreviation from a full stop: "e.g. ",
 * "Mr. " and "vs. " end in a period and none of them ends a sentence, nor does
 * a list item's "3. " at the start of a line. "I said no. We" and "I'm 25. My"
 * do end one. A port of the iOS keyboard's `SentenceBoundary`, with its list.
 */
internal object SentenceBoundary {
    /**
     * Not "no": "No. 5" is rare next to a sentence that ends in "no".
     */
    val ABBREVIATIONS: Set<String> = setOf(
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st",
        "e.g", "i.e", "etc", "vs", "approx", "dept", "est",
        "fig", "vol", "p", "pp", "al", "inc", "ltd", "co",
    )

    /**
     * Whether [token], the text since the last space, ends in a period that
     * is not the end of a sentence: an abbreviation, or a list number ("3")
     * when [atLineStart] says the token begins its line. A number anywhere
     * else ends its sentence like any word. Leading opening punctuation is
     * ignored: "(e.g".
     */
    fun isAbbreviation(token: String, atLineStart: Boolean = false): Boolean {
        val trimmed = token.trimStart { it in "(\"'[{“‘" }.removeSuffix(".")
        if (trimmed.isEmpty()) return false
        if (trimmed.all(Char::isDigit)) return atLineStart
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
        val line = beforeStop.dropLast(token.length)
        return !isAbbreviation(token, atLineStart = line.isEmpty() || line.endsWith("\n"))
    }
}
