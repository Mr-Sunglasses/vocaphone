package com.vocahq.vocaphone.core

import kotlin.math.abs

/**
 * Puts the user's own vocabulary back into a finished transcript, whatever
 * model produced it.
 *
 * Only Whisper takes a prompt, so a list of names did nothing for Parakeet,
 * SenseVoice or any other sherpa model. This runs after the model on every
 * route and fixes the two mistakes a recognizer makes with a word it was never
 * taught:
 *
 * - **Spacing and case.** "whisper kit", "Vocaphone", "voca phone" for
 *   "WhisperKit" and "VocaPhone". The letters match exactly once spaces and
 *   case are gone, so the replacement is certain.
 * - **One letter out.** "Kanish" for "Kanishk", "vocal phone" for "VocaPhone".
 *   Deliberately narrow: within one edit for most terms and two for long ones,
 *   the same first letter, and never an ordinary dictionary word on its own —
 *   "strip" is a word, and must not become "Stripe" because someone works there.
 *
 * What it will not do is hear "Cooper Netties" as "Kubernetes". That takes a
 * model that was listening; this only has the text.
 *
 * Mirrors `VocabularyCorrection.swift`.
 */
object VocabularyCorrection {
    /** Shorter terms are too easily one letter from something else. */
    const val MINIMUM_TERM_LENGTH = 4

    /**
     * How many transcript words one term may be matched against beyond its own
     * word count: a recognizer splits an unfamiliar word in two ("voca phone")
     * more often than it joins two into one.
     */
    private const val EXTRA_WORDS = 1

    fun apply(
        text: String,
        terms: List<String>,
        isDictionaryWord: (String) -> Boolean = { false },
    ): String {
        val candidates = terms.mapNotNull(Term::of).sortedByDescending { it.key.length }
        if (candidates.isEmpty() || text.isEmpty()) return text
        val words = words(text)
        if (words.isEmpty()) return text

        val replacements = mutableListOf<Pair<IntRange, String>>()
        var index = 0
        while (index < words.size) {
            var bestLength = 0
            var bestTerm: Term? = null
            var bestDistance = Int.MAX_VALUE
            for (term in candidates) {
                val longest = minOf(term.wordCount + EXTRA_WORDS, words.size - index)
                for (length in longest downTo 1) {
                    val span = words.subList(index, index + length)
                    if (!isContiguous(span, text)) continue
                    val key = span.joinToString("") { it.key }
                    val distance = term.accepts(
                        key,
                        wordCount = length,
                        isDictionaryWord = length == 1 && isDictionaryWord(key),
                    ) ?: continue
                    // A term already written correctly still wins here, so a
                    // longer near-miss cannot swallow it with the next word.
                    if (distance < bestDistance || (distance == bestDistance && length > bestLength)) {
                        bestLength = length
                        bestTerm = term
                        bestDistance = distance
                    }
                }
            }
            val term = bestTerm
            if (term != null) {
                val range = words[index].start until words[index + bestLength - 1].end
                if (text.substring(range.first, range.last + 1) != term.text) {
                    replacements += range to term.text
                }
                index += bestLength
            } else {
                index += 1
            }
        }
        if (replacements.isEmpty()) return text
        val result = StringBuilder(text)
        for ((range, replacement) in replacements.asReversed()) {
            result.replace(range.first, range.last + 1, replacement)
        }
        return result.toString()
    }

    private class Term(val text: String, val key: String, val wordCount: Int) {
        /** The edit distance at which [candidate] is taken to be this term, or null. */
        fun accepts(candidate: String, wordCount: Int, isDictionaryWord: Boolean): Int? {
            if (candidate == key) return 0
            // An ordinary word on its own is only ever the term if it *is* the
            // term; anything else is a real word the user said.
            if (isDictionaryWord || candidate.firstOrNull() != key.firstOrNull()) return null
            val allowed = if (key.length >= 11) 2 else 1
            if (abs(candidate.length - key.length) > allowed) return null
            // One word against a one-word term needs the stricter bar: that is
            // where a real word sits one letter from a name.
            if (wordCount == 1 && this.wordCount == 1 && key.length < 6) return null
            val distance = distance(candidate, key, allowed)
            return distance.takeIf { it <= allowed }
        }

        companion object {
            fun of(text: String): Term? {
                val key = key(text)
                if (key.length < MINIMUM_TERM_LENGTH) return null
                return Term(text, key, words(text).size.coerceAtLeast(1))
            }
        }
    }

    internal data class Word(val start: Int, val end: Int, val key: String)

    /**
     * Runs of letters and digits. An apostrophe ends a word, so "Kanish's" is
     * corrected to "Kanishk's" and the possessive stays where it was.
     */
    internal fun words(text: String): List<Word> {
        val words = mutableListOf<Word>()
        var start = -1
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            val isWordCharacter = Character.isLetterOrDigit(codePoint)
            if (isWordCharacter && start < 0) start = index
            if (!isWordCharacter && start >= 0) {
                words += Word(start, index, key(text.substring(start, index)))
                start = -1
            }
            index += Character.charCount(codePoint)
        }
        if (start >= 0) words += Word(start, text.length, key(text.substring(start)))
        return words
    }

    /** Words joined by nothing but spaces. A term must not swallow a comma. */
    private fun isContiguous(span: List<Word>, text: String): Boolean {
        for (i in 1 until span.size) {
            val gap = text.substring(span[i - 1].end, span[i].start)
            if (gap.isEmpty() || gap.any { it != ' ' }) return false
        }
        return true
    }

    internal fun key(text: String): String =
        text.lowercase().filter { it.isLetterOrDigit() }

    /** Levenshtein distance, giving up once it is past [limit]. */
    internal fun distance(lhs: String, rhs: String, limit: Int): Int {
        if (lhs.isEmpty()) return rhs.length
        if (rhs.isEmpty()) return lhs.length
        var previous = IntArray(rhs.length + 1) { it }
        var current = IntArray(rhs.length + 1)
        for (i in 1..lhs.length) {
            current[0] = i
            var rowMinimum = i
            for (j in 1..rhs.length) {
                val substitution = previous[j - 1] + if (lhs[i - 1] == rhs[j - 1]) 0 else 1
                current[j] = minOf(previous[j] + 1, current[j - 1] + 1, substitution)
                rowMinimum = minOf(rowMinimum, current[j])
            }
            if (rowMinimum > limit) return limit + 1
            val swap = previous
            previous = current
            current = swap
        }
        return previous[rhs.length]
    }
}
