package com.vocahq.vocaphone.core

import kotlin.math.abs
import kotlin.math.min

/**
 * Names and identifiers in the text around the cursor: the words a speech
 * model is most likely to get wrong and the person is most likely to say.
 * Mirrors `ContextTerms.swift` on iOS, and is ported from VocaMac's
 * `ScreenContextTerms`, which reads the focused field through Accessibility.
 *
 * A phone keyboard already sees that text. The keyboard reads it when a
 * dictation starts and [com.vocahq.vocaphone.dictation.DictationController]
 * turns it into terms in the same process; the text is dropped there and the
 * terms live in memory for that one dictation. They are used two ways: as the
 * least important recognition hints ([RecognitionHints.terms]), and by
 * [correct], which respells a transcript word only when its letters match a
 * term exactly.
 */
object ContextTerms {

    /** As many as [RecognitionHints] will take from this source. */
    const val MAX_TERMS = RecognitionHints.MAX_CONTEXT_TERMS

    /**
     * How much text either side of the cursor is read. A message or two:
     * enough for the names in a conversation, little enough to read in one go.
     */
    const val MAX_CHARACTERS_EACH_SIDE = 1_000

    // Extraction

    /**
     * Not inside a longer run of letters, digits or underscores. Written out
     * rather than `\b` so Java and ICU agree on every character.
     */
    private const val START = "(?<![\\p{L}\\p{N}_])"
    private const val END = "(?![\\p{L}\\p{N}_])"

    private val patterns = listOf(
        // camelCase and iOS-style names: userId, iPhone, macOS
        "[a-z][a-z0-9]*[A-Z][A-Za-z0-9]*",
        // Capitals inside a word: GitHub, OpenAI, UserService
        "[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*",
        // snake_case and SCREAMING_CASE
        "[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+",
        // kebab-case
        "[a-z][a-z0-9]*(?:-[a-z0-9]+)+",
    ).map { Regex(START + it + END) }

    /**
     * Capitalized words; kept only when they do not start a sentence and are
     * not ordinary words, which would make "Apple" out of "apple".
     */
    private val capitalizedWord = Regex("$START[A-Z][a-z]{2,}$END")

    /**
     * Words that start with two capitals: CUDA, ONNX, OAuth, URLSession. Not in
     * VocaMac; added because acronyms are much of what people dictate at work.
     * Kept only when they are not an ordinary word in capitals ("PLEASE"),
     * wherever they stand in a sentence.
     */
    private val acronym = Regex("$START[A-Z][A-Z0-9]+(?:[a-z][A-Za-z0-9]*)?$END")

    /**
     * The terms in the text either side of the cursor, most relevant first, at
     * most [MAX_TERMS]. Reads at most [MAX_CHARACTERS_EACH_SIDE] of each,
     * nearest the cursor.
     *
     * [isKnownWord] answers for a lowercased word: is it ordinary English? Pass
     * `{ true }` when no word list is at hand, which keeps only the identifier
     * shapes and drops every capitalized word.
     */
    fun extract(before: String?, after: String?, isKnownWord: (String) -> Boolean): List<String> {
        val head = before.orEmpty().takeLast(MAX_CHARACTERS_EACH_SIDE)
        val tail = after.orEmpty().take(MAX_CHARACTERS_EACH_SIDE)
        return extractFrom(head + tail, head.length, isKnownWord)
    }

    /**
     * The terms in [text], ranked: shown more often first (up to three times;
     * past that, more says little), then nearest [caret], a UTF-16 offset, then
     * first shown. Without a caret, the middle of the text.
     */
    fun extractFrom(text: String, caret: Int? = null, isKnownWord: (String) -> Boolean): List<String> {
        if (text.isEmpty()) return emptyList()
        val found = mutableListOf<Pair<Int, String>>()
        for (regex in patterns) {
            regex.findAll(text).forEach { found += it.range.first to it.value }
        }
        acronym.findAll(text).forEach { match ->
            if (!isKnownWord(match.value.lowercase())) found += match.range.first to match.value
        }
        capitalizedWord.findAll(text).forEach { match ->
            if (!startsSentence(match.range.first, text) && !isKnownWord(match.value.lowercase())) {
                found += match.range.first to match.value
            }
        }

        val focus = caret ?: (text.length / 2)
        val ranked = HashMap<String, Rank>()
        val counted = HashSet<String>()
        for ((location, term) in found) {
            if (VocabularyCorrection.key(term).length < 3) continue
            // Two patterns can match the same word; it was still shown once.
            if (!counted.add("$location:$term")) continue
            val distance = abs(location - focus)
            val rank = ranked[term]
            ranked[term] = if (rank == null) {
                Rank(1, distance, location)
            } else {
                Rank(rank.count + 1, min(rank.distance, distance), min(rank.first, location))
            }
        }
        return ranked.entries
            .sortedWith(
                compareByDescending<Map.Entry<String, Rank>> { min(it.value.count, 3) }
                    .thenBy { it.value.distance }
                    .thenBy { it.value.first }
                    .thenBy { it.key },
            )
            .take(MAX_TERMS)
            .map { it.key }
    }

    private data class Rank(val count: Int, val distance: Int, val first: Int)

    /**
     * Whether the word at [location] opens a sentence or a line, where a
     * capital letter says nothing about it being a name. The start of the text
     * counts: what was read may begin mid-sentence.
     */
    private fun startsSentence(location: Int, text: String): Boolean {
        var index = location - 1
        while (index >= 0) {
            val unit = text[index]
            if (unit == ' ' || unit == '\t') {
                index--
                continue
            }
            return unit in SENTENCE_OPENERS
        }
        return true
    }

    /** Newline, sentence ends, quotes and the marks that start a list item or a heading. */
    private const val SENTENCE_OPENERS = "\n\r.!?\"“#-*>"

    // Correction

    /** A code identifier rather than a name: camelCase, or anything with an underscore, hyphen, dot or digit. */
    fun isIdentifierShaped(term: String): Boolean {
        val first = term.firstOrNull() ?: return false
        if (first.isLowerCase() && term.any { it.isUpperCase() }) return true
        return term.any { it == '_' || it == '-' || it == '.' || it.isDigit() }
    }

    /** The longest run of transcript words one term is matched against. */
    private const val MAX_SPAN = 4

    private class Term(
        val text: String,
        val wordCount: Int,
        val joiners: Set<Char>,
        val identifier: Boolean,
    )

    /**
     * [text] with each run of words whose letters and digits are exactly a
     * term's, ignoring case and spacing, written as the term is: "git hub"
     * becomes "GitHub" when the field shows GitHub. Never a near miss: the
     * field only says a word is on screen, not that the person said it.
     *
     * - The user's own [vocabulary] wins: a term with the same letters as one
     *   of theirs is dropped, so their spelling, applied before this, stays.
     * - A single ordinary word ([isDictionaryWord], lowercased) is never
     *   respelled, whatever the term: "email" stays "email" when the field
     *   shows `e-mail`.
     * - An identifier ([isIdentifierShaped]) only ever replaces one word, so
     *   "set up" never becomes `setUp`.
     * - Words overlapping [protectedRanges], snippet triggers, are left alone.
     */
    fun correct(
        text: String,
        terms: List<String>,
        vocabulary: List<String> = emptyList(),
        isDictionaryWord: (String) -> Boolean = { false },
        protectedRanges: List<IntRange> = emptyList(),
    ): String {
        if (text.isEmpty() || terms.isEmpty()) return text
        val userKeys = vocabulary.mapTo(HashSet()) { VocabularyCorrection.key(it) }
        val exact = HashMap<String, Term>()
        for (term in terms) {
            val key = VocabularyCorrection.key(term)
            if (key.length < VocabularyCorrection.MINIMUM_TERM_LENGTH || key in userKeys || key in exact) continue
            exact[key] = Term(
                text = term,
                wordCount = maxOf(1, VocabularyCorrection.words(term).size),
                joiners = term.filterNot { it.isLetterOrDigit() }.toSet() + ' ',
                identifier = isIdentifierShaped(term),
            )
        }
        if (exact.isEmpty()) return text
        val words = VocabularyCorrection.words(text)
        val protected = words.indices.filter { index ->
            val word = words[index]
            protectedRanges.any { it.first < word.end && word.start <= it.last }
        }.toSet()

        val replacements = mutableListOf<Pair<IntRange, String>>()
        var index = 0
        while (index < words.size) {
            var matched = 0
            for (length in min(MAX_SPAN, words.size - index) downTo 1) {
                val span = words.subList(index, index + length)
                if ((index until index + length).any { it in protected }) continue
                val term = exact[span.joinToString("") { it.key }] ?: continue
                if (length > term.wordCount + 1) continue
                if (length > 1 && term.identifier) continue
                if (length == 1 && isDictionaryWord(span[0].key)) continue
                if (!isContiguous(span, text, term.joiners)) continue
                val range = span.first().start until span.last().end
                if (text.substring(range.first, range.last + 1) != term.text) {
                    replacements += range to term.text
                }
                matched = length
                break
            }
            index += maxOf(matched, 1)
        }
        if (replacements.isEmpty()) return text
        val result = StringBuilder(text)
        for ((range, term) in replacements.asReversed()) {
            result.replace(range.first, range.last + 1, term)
        }
        return result.toString()
    }

    /** Words joined only by [joiners]: "hub, and" must not be swallowed whole. */
    private fun isContiguous(span: List<VocabularyCorrection.Word>, text: String, joiners: Set<Char>): Boolean {
        for (i in 1 until span.size) {
            val gap = text.substring(span[i - 1].end, span[i].start)
            if (gap.isEmpty() || gap.any { it !in joiners }) return false
        }
        return true
    }
}
