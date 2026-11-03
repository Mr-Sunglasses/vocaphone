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
 * - **Sounds alike.** Double Metaphone ([DoubleMetaphone]) says when a heard
 *   spelling sounds like a term, and then the slip may be wider: one more edit,
 *   two more for a term of eight letters or more ("Postgersql" for
 *   "PostgreSQL", "Kayzer" for "Kaiser"), and the first letter may differ
 *   within one sound (c/k/q, s/z, f/ph). Only for a span with a word that is
 *   not an ordinary word: sounding alike is no reason to respell real ones.
 * - **Several words heard for one.** "cooper netties" for "Kubernetes", "pie
 *   torch" for "PyTorch": two or three words whose letters sound exactly like a
 *   term of six letters or more. Real words are never respelled on spelling
 *   alone, so this needs evidence the engine misheard them: the engine decoded
 *   one of the words with low confidence ([RecognitionConfidence]), or, for an
 *   engine that reports no confidence, one of them is not an ordinary word.
 *   Such an engine leaves a run of real words alone, and a single real word is
 *   never respelled —
 *   "cloud" stays "cloud" with Claude listed. VocaMac's rules.
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
     * certain in any language. [lowConfidenceWords] are the keys the engine
     * was unsure of ([RecognitionConfidence.lowConfidenceWords]), or null when
     * it reports nothing.
     *
     * Every term is used, however long the list. An exact match is a lookup;
     * for a near miss, terms are filed by first sound and length, the two
     * things every match already has to share, so each run of words is only
     * compared with the terms that could match it.
     */
    fun apply(
        text: String,
        terms: List<String>,
        isDictionaryWord: (String) -> Boolean = { false },
        protectedRanges: List<IntRange> = emptyList(),
        nearMisses: Boolean = true,
        lowConfidenceWords: Set<String>? = null,
    ): String {
        if (text.isEmpty()) return text
        val exact = HashMap<String, Term>()
        val filed = HashMap<Char, HashMap<Int, MutableList<Term>>>()
        var widest = 0
        for (term in terms.mapNotNull(Term::of)) {
            exact.putIfAbsent(term.key, term)
            filed.getOrPut(term.sound) { HashMap() }.getOrPut(term.key.length) { mutableListOf() } += term
            widest = maxOf(widest, term.wordCount + EXTRA_WORDS)
        }
        if (filed.isEmpty()) return text
        val words = words(text)
        if (words.isEmpty()) return text
        val protected = words.indices.filter { index ->
            val word = words[index]
            protectedRanges.any { it.first < word.end && word.start <= it.last }
        }.toSet()
        val search = Search(
            budget = if (nearMisses) FUZZY_COMPARISON_BUDGET else 0,
            phonetic = PhoneticKeys(),
        )

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
                if (search.budget <= 0 || key.isEmpty()) continue
                // An ordinary word on its own is only ever the term if it *is*
                // the term; anything else is a real word the user said.
                if (length == 1 && isDictionaryWord(key)) continue
                val candidate = Candidate(
                    key = key,
                    wordCount = length,
                    unknownWords = span.count { !isDictionaryWord(it.key) },
                )
                for (sound in soundsToSearch(key)) {
                    val byLength = filed[sound] ?: continue
                    for (termLength in maxOf(1, key.length - MAXIMUM_DISTANCE)..key.length + MAXIMUM_DISTANCE) {
                        for (term in byLength[termLength].orEmpty()) {
                            if (term.wordCount + EXTRA_WORDS < length) continue
                            if (!isContiguous(span, text, term.joiners)) continue
                            search.budget -= 1
                            val distance = term.accepts(candidate, search.phonetic) ?: continue
                            offer(term, length, distance)
                        }
                    }
                }
            }
            if (bestTerm == null && search.budget > 0) {
                soundAlikeJoin(index, words, text, filed, protected, isDictionaryWord, lowConfidenceWords, search)
                    ?.let { (length, term) ->
                        bestLength = length
                        bestTerm = term
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

    /** The most edits any near miss is allowed: two for a long term, one more when it sounds alike. */
    private const val MAXIMUM_DISTANCE = 3

    /**
     * A sound-alike term must be at least this long, as in VocaMac: shorter
     * keys share their Metaphone keys with too many words.
     */
    private const val MINIMUM_SOUND_ALIKE_LENGTH = 5

    /** The shortest term a run of words may be joined into by sound alone. */
    private const val MINIMUM_JOINED_TERM_LENGTH = 6

    /** The most transcript words joined into one term by sound. */
    private const val MAXIMUM_JOINED_WORDS = 3

    /** What one transcript may still spend, and the keys it has worked out. */
    private class Search(var budget: Int, val phonetic: PhoneticKeys)

    private class Candidate(
        /** The span's words' keys, joined. */
        val key: String,
        val wordCount: Int,
        /** How many of the span's words are not ordinary words. */
        val unknownWords: Int,
    ) {
        /**
         * Whether sounding like [term] may widen the match: a word in the span
         * is not an ordinary word — every word, when the span has more words
         * than the term, so the wider budget never takes a real word along
         * with the name beside it.
         */
        fun mayWiden(term: Term): Boolean =
            if (wordCount > term.wordCount) unknownWords == wordCount else unknownWords > 0
    }

    private class Term(val text: String, val key: String, val sound: Char, val wordCount: Int) {
        /**
         * What may sit between the transcript words matched against this term:
         * a space, and whatever punctuation the term itself uses inside it, so
         * "o'brien" can become "O'Brien" without a term swallowing punctuation
         * it never had.
         */
        val joiners: Set<Char> = text.filterNot { it.isLetterOrDigit() }.toSet() + ' '

        /**
         * The edit distance at which [candidate] is taken to be this term, or
         * null. A single ordinary word never gets here.
         */
        fun accepts(candidate: Candidate, phonetic: PhoneticKeys): Int? {
            val heard = candidate.key
            if (heard == key) return 0
            // One word against a one-word term needs the stricter bar: that is
            // where a real word sits one letter from a name.
            if (candidate.wordCount == 1 && wordCount == 1 && key.length < 6) return null
            val sameLetter = heard.firstOrNull() == key.firstOrNull()
            if (!sameLetter && firstSound(heard) != sound) return null
            var allowed = if (key.length >= 11) 2 else 1
            val alike = candidate.mayWiden(this) && key.length >= MINIMUM_SOUND_ALIKE_LENGTH &&
                abs(heard.length - key.length) <= MAXIMUM_DISTANCE &&
                phonetic.soundAlike(heard, key)
            if (alike) {
                allowed = if (key.length >= 8) maxOf(allowed + 1, 3) else allowed + 1
            }
            // A different first letter is only the same first sound when the
            // whole word sounds alike: "Kayzer" may be "Caesar", "cable" not.
            if (!sameLetter && !alike) return null
            if (abs(heard.length - key.length) > allowed) return null
            val distance = distance(heard, key, allowed)
            return distance.takeIf { it <= allowed }
        }

        companion object {
            fun of(text: String): Term? {
                val key = key(text)
                if (key.length < MINIMUM_TERM_LENGTH) return null
                val sound = firstSound(key) ?: return null
                return Term(text, key, sound, words(text).size.coerceAtLeast(1))
            }
        }
    }

    /** Double Metaphone keys, worked out once per dictation and spelling. */
    private class PhoneticKeys {
        private val keys = HashMap<String, DoubleMetaphone.Key?>()

        fun key(text: String): DoubleMetaphone.Key? = keys.getOrPut(text) { DoubleMetaphone.encode(text) }

        /**
         * Whether two letter keys sound alike: their Double Metaphone keys meet,
         * or, for what Metaphone cannot key, their Soundex codes agree.
         */
        fun soundAlike(heard: String, term: String): Boolean {
            val heardKey = key(heard)
            val termKey = key(term)
            if (heardKey != null && termKey != null) return heardKey.matches(termKey)
            val code = soundex(heard) ?: return false
            return code == soundex(term)
        }
    }

    /**
     * Two or three words heard for one longer term that sounds exactly like
     * them: their joined letters and the term share a primary Metaphone key.
     * Needs evidence the engine misheard: a word it decoded with low
     * confidence, or, from an engine that reports no confidence, a word that is
     * not an ordinary word. The term itself must not be an ordinary word, or
     * "cooper" and "pans" could become "Copperpans".
     */
    private fun soundAlikeJoin(
        index: Int,
        words: List<Word>,
        text: String,
        filed: Map<Char, Map<Int, List<Term>>>,
        protected: Set<Int>,
        isDictionaryWord: (String) -> Boolean,
        lowConfidenceWords: Set<String>?,
        search: Search,
    ): Pair<Int, Term>? {
        val longest = minOf(MAXIMUM_JOINED_WORDS, words.size - index)
        if (longest < 2) return null
        for (length in longest downTo 2) {
            if ((index until index + length).any { it in protected }) continue
            val span = words.subList(index, index + length)
            if (!isContiguous(span, text, JOIN_JOINERS)) continue
            val keys = span.map { it.key }
            // An engine that reports confidence has said which words it
            // doubted, and a word missing from a 10 000-word list is no
            // evidence beside that: "said Ruth" is not "Siddharth" because
            // "Ruth" is a name. Only an engine that says nothing is judged
            // by the list.
            val misheard = if (lowConfidenceWords != null) {
                keys.any { it in lowConfidenceWords }
            } else {
                keys.any { !isDictionaryWord(it) }
            }
            if (!misheard) continue
            val joined = keys.joinToString("")
            val heardKey = search.phonetic.key(joined) ?: continue
            if (heardKey.primary.length < 3) continue
            // Closest length first, then the order the user wrote them in.
            val lengths = (MINIMUM_JOINED_TERM_LENGTH..maxOf(MINIMUM_JOINED_TERM_LENGTH, joined.length * 2))
                .filter { abs(it - joined.length) <= maxOf(2, it / 3) }
                .sortedWith(compareBy({ abs(it - joined.length) }, { it }))
            for (sound in soundsToSearch(joined)) {
                val byLength = filed[sound] ?: continue
                for (termLength in lengths) {
                    for (term in byLength[termLength].orEmpty()) {
                        if (search.budget <= 0) return null
                        search.budget -= 1
                        if (firstSound(joined) != term.sound) continue
                        if (search.phonetic.key(term.key)?.primary != heardKey.primary) continue
                        if (isDictionaryWord(term.key)) continue
                        return length to term
                    }
                }
            }
        }
        return null
    }

    private val JOIN_JOINERS = setOf(' ', '-')

    /**
     * Rough first sound, so a near miss never swaps a word for a term that
     * starts differently: c/k/q, s/z and ph/f are each one sound.
     */
    internal fun firstSound(key: String): Char? {
        if (key.startsWith("ph")) return 'f'
        return when (val first = key.firstOrNull() ?: return null) {
            'c', 'q' -> 'k'
            'z' -> 's'
            else -> first
        }
    }

    /**
     * The buckets that hold every term a key could be matched with: its own
     * first sound, and for a "p" word the "f" bucket too, where a "ph" term
     * with the same first letter is filed.
     */
    private fun soundsToSearch(key: String): List<Char> {
        val sound = firstSound(key) ?: return emptyList()
        if (key.first() != 'p') return listOf(sound)
        return if (sound == 'f') listOf('f', 'p') else listOf('p', 'f')
    }

    /**
     * American Soundex of a lowercase ASCII key, or null for anything else. It
     * only ever widens a match, never makes one.
     */
    internal fun soundex(key: String): String? {
        val first = key.firstOrNull() ?: return null
        if (!key.all { it in 'a'..'z' || it in 'A'..'Z' }) return null
        fun code(character: Char): Char? = when (character) {
            'b', 'f', 'p', 'v' -> '1'
            'c', 'g', 'j', 'k', 'q', 's', 'x', 'z' -> '2'
            'd', 't' -> '3'
            'l' -> '4'
            'm', 'n' -> '5'
            'r' -> '6'
            else -> null
        }
        val result = StringBuilder().append(first)
        var previous = code(first)
        for (character in key.drop(1)) {
            val current = code(character)
            if (current != null && current != previous) {
                result.append(current)
                if (result.length == 4) break
            }
            // "h" and "w" do not separate equal codes; vowels do.
            if (character != 'h' && character != 'w') previous = current
        }
        return result.toString().padEnd(4, '0')
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
