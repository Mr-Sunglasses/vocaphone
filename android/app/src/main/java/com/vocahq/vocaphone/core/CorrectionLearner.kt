package com.vocahq.vocaphone.core

import java.util.Locale

/**
 * Works out which words the user respelled in text a dictation typed, by
 * comparing the dictated span as it was inserted with the same span later.
 *
 * Only spelling fixes count: a name spelled differently, a casing change, or
 * words joined into one term. Rewording a sentence is the user writing, not a
 * transcription mistake, and is ignored; so is swapping one ordinary word for
 * another ("there" → "their"), which no dictionary entry could help with.
 *
 * A port of VocaMac's `CorrectionLearner`. Mirrors `CorrectionLearner.swift`;
 * both run the same cases in their tests.
 */
object CorrectionLearner {

    data class Correction(val heard: String, val corrected: String)

    /** Longest edited region, in words, that is still a fix rather than a rewrite. */
    const val MAXIMUM_EDITED_WORDS = 12

    /** A half-open range of character offsets. */
    data class Span(val start: Int, val end: Int) {
        val length: Int get() = end - start
        fun contains(offset: Int) = offset in start until end
        fun overlaps(other: Span) = start < other.end && other.start < end
    }

    /**
     * Corrections the user made inside the dictated text.
     *
     * @param inserted The text the dictation typed.
     * @param before The text around it just after it was typed.
     * @param after The same text now.
     * @param caretLocation Caret position in [before], used to find the right
     *   copy of [inserted] when it appears more than once.
     * @param isKnownWord Whether a lowercase word is ordinary vocabulary.
     */
    fun corrections(
        inserted: String,
        before: String,
        after: String,
        caretLocation: Int? = null,
        isKnownWord: (String) -> Boolean,
    ): List<Correction> {
        val dictated = inserted.trim()
        if (dictated.isEmpty() || before == after) return emptyList()
        val insertedRange = locate(dictated, before, caretLocation) ?: return emptyList()
        val old = before
        val new = after

        // The single region where the two texts differ.
        var prefix = 0
        while (prefix < old.length && prefix < new.length && old[prefix] == new[prefix]) prefix++
        var suffix = 0
        while (suffix < old.length - prefix && suffix < new.length - prefix &&
            old[old.length - 1 - suffix] == new[new.length - 1 - suffix]
        ) {
            suffix++
        }

        // Widen to whole words so "Namratha" → "Namrata" compares whole names.
        while (prefix > 0 && isWordCharacter(old[prefix - 1])) prefix--
        while (suffix > 0 && isWordCharacter(old[old.length - suffix])) suffix--

        val oldChanged = Span(prefix, old.length - suffix)
        val newChanged = Span(prefix, new.length - suffix)
        val touches = oldChanged.overlaps(insertedRange) ||
            (oldChanged.length == 0 && insertedRange.contains(prefix))
        if (!touches) return emptyList()
        // An edit reaching well outside the dictation is the user writing.
        if (oldChanged.start < insertedRange.start - 1 || oldChanged.end > insertedRange.end + 1) {
            return emptyList()
        }

        val oldWords = words(old.substring(oldChanged.start, oldChanged.end))
        // Which corrected words open a sentence: there a capital is only
        // sentence case, not evidence of a name.
        val opensSentence = new.substring(0, newChanged.start)
            .lastOrNull { !it.isWhitespace() || it == '\n' || it == '\r' }
            ?.let { it == '\n' || it == '\r' || it in SENTENCE_ENDS }
            ?: true
        val newTokens = wordsMarkingSentenceStarts(new.substring(newChanged.start, newChanged.end), opensSentence)
        val newWords = newTokens.map { it.first }
        if (oldWords.isEmpty() || newWords.isEmpty() ||
            oldWords.size > MAXIMUM_EDITED_WORDS || newWords.size > MAXIMUM_EDITED_WORDS
        ) {
            return emptyList()
        }

        val found = mutableListOf<Correction>()
        for (block in substitutions(oldWords, newWords)) {
            if (block.old.size !in 1..3 || block.new.size !in 1..2) continue
            val heard = block.old.joinToString(" ")
            val corrected = block.new.joinToString(" ")
            val atSentenceStart = newTokens.getOrNull(block.newStart)?.second == true
            if (isLikelyCorrection(heard, corrected, atSentenceStart, isKnownWord)) {
                found += Correction(heard, corrected)
            }
        }
        return found.take(3)
    }

    /**
     * Whether changing [heard] to [corrected] looks like fixing a
     * transcription (spelling, casing, joining) rather than rewording.
     *
     * @param atSentenceStart [corrected] opens a sentence, so its first capital
     *   is sentence case: "Whether is nice" → "Weather is nice" swaps two
     *   ordinary words, it doesn't name anything.
     */
    fun isLikelyCorrection(
        heard: String,
        corrected: String,
        atSentenceStart: Boolean = false,
        isKnownWord: (String) -> Boolean,
    ): Boolean {
        if (heard == corrected || corrected.length > 40 || corrected.none { it.isLetter() }) return false
        val heardKey = VocabularyCorrection.key(heard)
        val correctedKey = VocabularyCorrection.key(corrected)
        if (correctedKey.length < 2 || heardKey.isEmpty()) return false

        if (heardKey == correctedKey) {
            // Same letters: a casing or joining fix. Capitalizing an ordinary
            // word ("hello" → "Hello") is sentence case, not a new term.
            if (isSentenceCase(corrected) && ' ' !in corrected && isKnownWord(lower(corrected))) return false
            return true
        }

        // Swapping one ordinary word for another ("their" → "there") is a
        // grammar fix the dictionary can't help with.
        val correctedWords = corrected.split(' ').filter { it.isNotEmpty() }
        if (corrected == lower(corrected) && correctedWords.all(isKnownWord)) return false
        // The same at a sentence start, where the first capital is the
        // sentence's: "Their" → "There", "Whether" → "Weather".
        if (atSentenceStart && isSentenceCase(corrected) && correctedWords.all { isKnownWord(lower(it)) }) {
            return false
        }

        if (VocabularyCorrection.firstSound(heardKey) != VocabularyCorrection.firstSound(correctedKey)) return false
        val longest = maxOf(heardKey.length, correctedKey.length)
        val distance = VocabularyCorrection.distance(heardKey, correctedKey, longest)
        return distance.toDouble() / longest <= 0.4
    }

    /**
     * Where [needle] sits in [haystack], preferring the copy ending nearest
     * the caret (the one just typed), else the last.
     */
    fun locate(needle: String, haystack: String, caretLocation: Int?): Span? {
        if (needle.isEmpty() || needle.length > haystack.length) return null
        val ranges = mutableListOf<Span>()
        var start = haystack.indexOf(needle)
        while (start >= 0) {
            ranges += Span(start, start + needle.length)
            start = haystack.indexOf(needle, start + needle.length)
        }
        if (caretLocation == null) return ranges.lastOrNull()
        return ranges.minByOrNull { kotlin.math.abs(it.end - caretLocation) }
    }

    /**
     * Whether [edited] is still the dictation, edited, rather than what
     * replaced it after it was sent or deleted: half of a longer dictation's
     * words are still there, or a short one is still spelled mostly the same
     * ("Pria" → "Priya", not "hello there" → "ok").
     */
    fun isStillDictation(edited: String, dictated: String): Boolean {
        val dictatedWords = plainWords(dictated)
        val editedWords = plainWords(edited)
        if (editedWords.isEmpty()) return false
        if (dictatedWords.size >= 4) {
            val remaining = editedWords.groupingBy { it }.eachCount().toMutableMap()
            var kept = 0
            for (word in dictatedWords) {
                val left = remaining[word] ?: 0
                if (left > 0) {
                    remaining[word] = left - 1
                    kept++
                }
            }
            return kept * 2 >= dictatedWords.size
        }
        val a = dictatedWords.joinToString(" ")
        val b = editedWords.joinToString(" ")
        val longest = maxOf(a.length, b.length)
        return VocabularyCorrection.distance(a, b, longest) <= longest * 0.5
    }

    /**
     * Whether [text] reads as the language [isKnownWord] knows: at least half
     * its words are in the list. Learning leans on that list to tell rewording
     * from respelling, so text in another language — where every word looks
     * unknown — is not learned from at all.
     */
    fun readsAsKnownLanguage(text: String, isKnownWord: (String) -> Boolean): Boolean {
        val words = plainWords(text).filter { word -> word.any { it.isLetter() } }
        if (words.isEmpty()) return false
        return words.count(isKnownWord) * 2 >= words.size
    }

    /** Whether [text] is one ordinary word, so a replacement from it would rewrite ordinary speech. */
    fun isOrdinaryWord(text: String, isKnownWord: (String) -> Boolean): Boolean {
        val words = plainWords(text)
        return words.size == 1 && isKnownWord(words[0])
    }

    /**
     * Whether a fix names something: it has a capital ("Priya", "GitHub") or
     * a word the list doesn't know ("kubectl"). A plain lowercase word is
     * grammar, not spelling.
     */
    fun namesATerm(corrected: String, isKnownWord: (String) -> Boolean): Boolean {
        if (corrected.any { it.isUpperCase() }) return true
        return corrected.split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }.any { !isKnownWord(lower(it)) }
    }

    // MARK: - Words

    private fun words(text: String): List<String> =
        text.split(WHITESPACE).map(::trimmedWord).filter { it.isNotEmpty() }

    /** Lowercased runs of letters, digits and apostrophes. */
    private fun plainWords(text: String): List<String> =
        lower(text).split(Regex("[^\\p{L}\\p{N}'’]+")).filter { it.isNotEmpty() }

    private fun trimmedWord(token: String): String =
        token.trim { isPunctuation(it) && it !in KEPT_IN_WORDS }.trim('.')

    /**
     * Words of [text], each marked with whether it opens a sentence: it comes
     * first and [startsSentence], or follows a line break or a token ending in
     * `.` `!` `?` `…`.
     */
    internal fun wordsMarkingSentenceStarts(text: String, startsSentence: Boolean): List<Pair<String, Boolean>> {
        val result = mutableListOf<Pair<String, Boolean>>()
        var opens = startsSentence
        val token = StringBuilder()
        fun finish() {
            if (token.isEmpty()) return
            val word = trimmedWord(token.toString())
            if (word.isNotEmpty()) result += word to opens
            val end = token.toString().trimEnd { it in CLOSERS }
            val last = end.lastOrNull()
            if (last != null) {
                opens = last in SENTENCE_ENDS
            } else if (word.isNotEmpty()) {
                opens = false
            }
            token.setLength(0)
        }
        for (character in text) {
            if (character.isWhitespace()) {
                finish()
                if (character == '\n' || character == '\r') opens = true
            } else {
                token.append(character)
            }
        }
        finish()
        return result
    }

    private class Block(val old: List<String>, val new: List<String>, val newStart: Int)

    /**
     * Runs of words that were replaced, from a longest-common-subsequence
     * alignment of the two word lists.
     */
    private fun substitutions(old: List<String>, new: List<String>): List<Block> {
        val table = Array(old.size + 1) { IntArray(new.size + 1) }
        for (i in old.indices.reversed()) {
            for (j in new.indices.reversed()) {
                table[i][j] = if (old[i] == new[j]) table[i + 1][j + 1] + 1 else maxOf(table[i + 1][j], table[i][j + 1])
            }
        }
        val blocks = mutableListOf<Block>()
        val pendingOld = mutableListOf<String>()
        val pendingNew = mutableListOf<String>()
        var i = 0
        var j = 0
        fun flush() {
            if (pendingOld.isNotEmpty() && pendingNew.isNotEmpty()) {
                blocks += Block(pendingOld.toList(), pendingNew.toList(), j - pendingNew.size)
            }
            pendingOld.clear()
            pendingNew.clear()
        }
        while (i < old.size || j < new.size) {
            if (i < old.size && j < new.size && old[i] == new[j]) {
                flush()
                i++
                j++
            } else if (j < new.size && (i == old.size || table[i][j + 1] >= table[i + 1][j])) {
                pendingNew += new[j]
                j++
            } else {
                pendingOld += old[i]
                i++
            }
        }
        flush()
        return blocks
    }

    private fun isSentenceCase(text: String): Boolean =
        text.isNotEmpty() && text == text.substring(0, 1).uppercase(Locale.ROOT) + lower(text.substring(1))

    private fun lower(text: String) = text.lowercase(Locale.ROOT)

    private fun isWordCharacter(character: Char): Boolean =
        character.isLetterOrDigit() || character == '_' || character == '\'' || character == '’'

    private fun isPunctuation(character: Char): Boolean = when (Character.getType(character).toByte()) {
        Character.CONNECTOR_PUNCTUATION,
        Character.DASH_PUNCTUATION,
        Character.START_PUNCTUATION,
        Character.END_PUNCTUATION,
        Character.INITIAL_QUOTE_PUNCTUATION,
        Character.FINAL_QUOTE_PUNCTUATION,
        Character.OTHER_PUNCTUATION,
        -> true
        else -> false
    }

    private val WHITESPACE = Regex("\\s+")
    private const val SENTENCE_ENDS = ".!?…"
    private const val KEPT_IN_WORDS = "'’-_."
    private const val CLOSERS = "\"'”’)]"
}
