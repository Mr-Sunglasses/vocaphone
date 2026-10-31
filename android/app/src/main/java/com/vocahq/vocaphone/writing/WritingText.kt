package com.vocahq.vocaphone.writing

/**
 * The word split every part of Writing check reads: rules, the model's edits,
 * tone and statistics. Offsets are UTF-16 units, the same on both platforms
 * (`NSString` on iOS), so a suggestion found on one side lands on the same
 * characters on the other. Mirrors `ios/VocaPhoneShared/Writing/WritingText.swift`.
 *
 * A word is a run of letters and digits with inner apostrophes ("don't" is one
 * word); anything else that is not space is a token of one code point.
 */
data class WritingToken(val text: String, val start: Int, val end: Int, val isWord: Boolean) {
    /** Lowercase, apostrophes straight: what rules and tables compare. */
    val key: String = normalize(text)

    val hasLetter: Boolean get() = isWord && text.any(Char::isLetter)

    companion object {
        fun normalize(text: String): String = text.lowercase().replace('’', '\'')
    }
}

/**
 * Token indices `[first, last]` and their UTF-16 range. [paragraph] counts
 * line breaks seen before the sentence.
 */
data class WritingSentence(val first: Int, val last: Int, val start: Int, val end: Int, val paragraph: Int)

object WritingText {
    fun tokenize(text: String): List<WritingToken> {
        val out = ArrayList<WritingToken>()
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            val n = Character.charCount(cp)
            when {
                isSpace(cp) -> i += n
                isWordChar(cp) -> {
                    val start = i
                    i += n
                    while (i < text.length) {
                        val c = text.codePointAt(i)
                        if (isWordChar(c)) {
                            i += Character.charCount(c)
                            continue
                        }
                        if (isApostrophe(c) && i + 1 < text.length && isWordChar(text.codePointAt(i + 1))) {
                            i += 1
                            continue
                        }
                        break
                    }
                    out.add(WritingToken(text.substring(start, i), start, i, true))
                }
                else -> {
                    out.add(WritingToken(text.substring(i, i + n), i, i + n, false))
                    i += n
                }
            }
        }
        return out
    }

    fun sentences(text: String, tokens: List<WritingToken>): List<WritingSentence> {
        val out = ArrayList<WritingSentence>()
        var first = 0
        var paragraph = 0
        var i = 0
        while (i < tokens.size) {
            var last = i
            var boundary = false
            if (tokens[i].text in TERMINALS) {
                while (last + 1 < tokens.size && tokens[last + 1].text in CLOSERS && tokens[last + 1].start == tokens[last].end) {
                    last++
                }
                boundary = last + 1 == tokens.size || tokens[last + 1].start > tokens[last].end
            }
            val gap = if (last + 1 < tokens.size) text.substring(tokens[last].end, tokens[last + 1].start) else ""
            val lineBreak = gap.any { it in LINE_BREAKS }
            if (boundary || lineBreak || last + 1 == tokens.size) {
                out.add(WritingSentence(first, last, tokens[first].start, tokens[last].end, paragraph))
                first = last + 1
                if (lineBreak) paragraph++
            }
            i = last + 1
        }
        return out
    }

    /** Whether token [index] opens [sentence], past any opening quotes or brackets. */
    fun isSentenceStart(tokens: List<WritingToken>, sentence: WritingSentence, index: Int): Boolean {
        var j = index - 1
        while (j >= sentence.first && tokens[j].text in OPENERS) j--
        return j < sentence.first
    }

    /** Joins words with single spaces, attaching punctuation to the word before it. */
    fun join(parts: List<String>): String {
        val out = StringBuilder()
        parts.filter { it.isNotEmpty() }.forEachIndexed { i, part ->
            if (i > 0 && part !in ATTACHED) out.append(' ')
            out.append(part)
        }
        return out.toString()
    }

    fun isPunctuation(text: String): Boolean = text.isNotEmpty() && text.none(Char::isLetterOrDigit)

    private fun isWordChar(cp: Int): Boolean = when (Character.getType(cp).toByte()) {
        Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
        Character.MODIFIER_LETTER, Character.OTHER_LETTER, Character.DECIMAL_DIGIT_NUMBER,
        Character.LETTER_NUMBER, Character.OTHER_NUMBER,
        -> true
        else -> false
    }

    private fun isApostrophe(cp: Int) = cp == '\''.code || cp == '’'.code

    /** Python's `str.isspace()` set, as in the grammar tagger, so both platforms split alike. */
    private fun isSpace(cp: Int): Boolean = cp in 0x09..0x0D || cp in 0x1C..0x20 || cp == 0x85 || cp == 0xA0 ||
        cp == 0x1680 || cp in 0x2000..0x200A || cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F ||
        cp == 0x3000

    private val TERMINALS = setOf(".", "!", "?", "…")
    private val CLOSERS = setOf("\"", "'", "”", "’", ")", "]", "»")
    private val OPENERS = setOf("\"", "“", "'", "‘", "(", "[", "«")
    private val LINE_BREAKS = setOf('\n', '\r', ' ', ' ')
    private val ATTACHED = setOf(",", ".", ";", ":", "!", "?")
}
