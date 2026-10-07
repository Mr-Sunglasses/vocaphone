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
 *   English only: the dictionary that guards real words is the English one,
 *   so in any other language every word one letter from a term would be fair
 *   game — German "Wagen" would become a colleague called "Wagner".
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

    /** The longest run of transcript words ever compared with one term. */
    private const val MAXIMUM_SPAN = 8

    /**
     * How many near-miss comparisons one transcript may spend. Exact matches —
     * spacing and case — are a lookup and never count against it. A realistic
     * list of a few hundred names never comes close; a pasted list of thousands
     * that share their first letters stops looking for one-letter slips before
     * it can hold up the transcript.
     */
    const val FUZZY_COMPARISON_BUDGET = 60_000

    /**
     * [text] with every near-miss of a term in [terms] replaced by the term as
     * the user wrote it. A single [isDictionaryWord] is only ever replaced by an
     * exact match. Words that overlap [protectedRanges] — snippet triggers,
     * which expand after this runs — are never touched. With [nearMisses]
     * false only the spacing and case of a term are corrected, which is
     * certain in any language.
     *
     * Every term is used, however long the list. An exact match is a lookup;
     * for a near miss, terms are filed by first letter and length, the two
     * things every match already has to share within two.
     */
    fun apply(
        text: String,
        terms: List<String>,
        isDictionaryWord: (String) -> Boolean = { false },
        protectedRanges: List<IntRange> = emptyList(),
        nearMisses: Boolean = true,
    ): String {
        if (text.isEmpty()) return text
        val exact = HashMap<String, Term>()
        val filed = HashMap<Char, HashMap<Int, MutableList<Term>>>()
        var widest = 0
        for (term in terms.mapNotNull(Term::of)) {
            exact.putIfAbsent(term.key, term)
            filed.getOrPut(term.key.first()) { HashMap() }.getOrPut(term.key.length) { mutableListOf() } += term
            widest = maxOf(widest, term.wordCount + EXTRA_WORDS)
        }
        if (filed.isEmpty()) return text
        val words = words(text)
        if (words.isEmpty()) return text
        val protected = words.indices.filter { index ->
            val word = words[index]
            protectedRanges.any { it.first < word.end && word.start <= it.last }
        }.toSet()
        var budget = if (nearMisses) FUZZY_COMPARISON_BUDGET else 0

        val replacements = mutableListOf<Pair<IntRange, String>>()
        var index = 0
        while (index < words.size) {
            var bestLength = 0
            var bestTerm: Term? = null
            var bestDistance = Int.MAX_VALUE
            fun offer(term: Term, length: Int, distance: Int) {
                // A term already written correctly still wins here, so a longer
                // near-miss cannot swallow it with the next word.
                if (distance < bestDistance || (distance == bestDistance && length > bestLength)) {
                    bestLength = length
                    bestTerm = term
                    bestDistance = distance
                }
            }
            val longest = minOf(widest, MAXIMUM_SPAN, words.size - index)
            for (length in longest downTo 1) {
                if ((index until index + length).any { it in protected }) continue
                val span = words.subList(index, index + length)
                val key = span.joinToString("") { it.key }
                val exactTerm = exact[key]
                if (exactTerm != null && exactTerm.wordCount + EXTRA_WORDS >= length &&
                    isContiguous(span, text, exactTerm.joiners)
                ) {
                    offer(exactTerm, length, 0)
                    continue
                }
                if (budget <= 0) continue
                val byLength = key.firstOrNull()?.let { filed[it] } ?: continue
                val dictionaryWord = length == 1 && isDictionaryWord(key)
                for (termLength in maxOf(1, key.length - 2)..key.length + 2) {
                    for (term in byLength[termLength].orEmpty()) {
                        if (term.wordCount + EXTRA_WORDS < length) continue
                        if (!isContiguous(span, text, term.joiners)) continue
                        budget -= 1
                        val distance = term.accepts(key, length, dictionaryWord) ?: continue
                        offer(term, length, distance)
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
        /**
         * What may sit between the transcript words matched against this term:
         * a space, and whatever punctuation the term itself uses inside it, so
         * "o'brien" can become "O'Brien" without a term swallowing punctuation
         * it never had.
         */
        val joiners: Set<Char> = text.filterNot { it.isLetterOrDigit() }.toSet() + ' '

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

    /** Words joined only by [joiners]. A term must not swallow a comma. */
    private fun isContiguous(span: List<Word>, text: String, joiners: Set<Char>): Boolean {
        for (i in 1 until span.size) {
            val gap = text.substring(span[i - 1].end, span[i].start)
            if (gap.isEmpty() || gap.any { it !in joiners }) return false
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
