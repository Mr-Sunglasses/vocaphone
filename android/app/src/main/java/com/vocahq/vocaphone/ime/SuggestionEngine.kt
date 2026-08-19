package com.vocahq.vocaphone.ime

import android.content.res.AssetManager

/**
 * The typing dictionary, with the indexes that keep it off the frame budget.
 *
 * Every lookup here used to be a full scan of all ten thousand words, run from
 * composition on every keystroke: `complete` tested `startsWith` against each
 * one, `similar` ran a Damerau-Levenshtein matrix against each one — allocating
 * three `IntArray`s a word — and `swipe` rebuilt each word's collapsed spelling
 * from scratch. Typing a word the dictionary does not know cost roughly a
 * millisecond per keystroke on a desktop JVM, which is a dropped frame or
 * several on a phone, and it landed on exactly the keystrokes where the user is
 * mid-word and watching the strip.
 *
 * The indexes below are built once, at load, on whatever thread does the
 * loading — which is deliberately not the keyboard's. They cost about a
 * megabyte for the shipped list and turn all three scans into small ones. The
 * results are identical: every index preserves the frequency order of [words],
 * because that order is what the strip's ranking means.
 */
internal class SuggestionDictionary(
    private val words: List<String>,
    private val bigrams: Map<String, List<String>>,
) {
    private val known = words.toHashSet()

    /** `word.length`, unboxed, so the length filter never touches a String. */
    private val lengths = IntArray(words.size) { words[it].length }

    /**
     * Which letters each word contains, one bit per letter, with bit 26 for
     * anything outside a-z. Two words within edit distance 2 cannot differ by
     * more than four letters — each edit adds at most one letter and removes at
     * most one — so a word whose bit count differs by more is rejected before
     * the matrix runs. On the shipped list this declines around 95% of the
     * candidates that survive the length filter, for one xor and one popcount.
     */
    private val letterMasks = IntArray(words.size) { letterMask(words[it]) }

    /**
     * Indices of the words starting with each prefix of up to
     * [PREFIX_KEY_LENGTH] characters, ascending, so a bucket walk is still a
     * frequency-ordered walk. A longer prefix reuses the longest bucket it has
     * and re-tests `startsWith`, which is exact and cheap on a small bucket.
     */
    private val prefixIndex: Map<String, IntArray> = buildPrefixIndex(words)

    /** Each word's swipe spelling, collapsed once here instead of per gesture. */
    private val collapsed: Array<String> =
        Array(words.size) { SuggestionEngine.collapseLetters(words[it]) }

    /** Unboxed lengths for [collapsed], so the reject path never derefs a String. */
    private val collapsedLength = IntArray(words.size) { collapsed[it].length }

    fun isKnown(word: String): Boolean = known.contains(word.lowercase())

    fun complete(prefix: String, limit: Int = 3): List<String> {
        if (prefix.isEmpty()) return emptyList()
        val lower = prefix.lowercase()
        val bucket = prefixIndex[lower.take(PREFIX_KEY_LENGTH)] ?: return emptyList()
        val matches = ArrayList<String>(limit)
        for (index in bucket) {
            val word = words[index]
            if (lengths[index] <= lower.length || !word.startsWith(lower)) continue
            matches.add(SuggestionEngine.matchCase(prefix, word))
            if (matches.size == limit) break
        }
        return matches
    }

    fun next(previousWord: String, limit: Int = 3): List<String> {
        if (previousWord.isEmpty()) return emptyList()
        return bigrams[previousWord.lowercase()].orEmpty().take(limit)
    }

    fun correct(typed: String, limit: Int = 3): List<String> {
        val lower = typed.lowercase()
        if (lower.length < 2 || isKnown(lower)) return emptyList()
        return similar(typed, limit)
    }

    fun similar(typed: String, limit: Int = 3): List<String> {
        val lower = typed.lowercase()
        if (lower.length < 2) return emptyList()
        val neighbor = ArrayList<String>(limit)
        val distance1 = ArrayList<String>(limit)
        val distance2 = ArrayList<String>(limit)
        val minLen = (lower.length - 2).coerceAtLeast(1)
        val maxLen = lower.length + 2
        val typedMask = letterMask(lower)
        // One set of rows for the whole scan rather than three arrays per word.
        val scratch = SuggestionEngine.EditDistanceScratch(maxLen)
        for (index in words.indices) {
            val length = lengths[index]
            if (length < minLen || length > maxLen) continue
            if ((typedMask xor letterMasks[index]).countOneBits() > MAX_LETTER_DIFFERENCE) continue
            val word = words[index]
            if (word == lower) continue
            val distance = SuggestionEngine.editDistance(lower, word, max = 2, scratch = scratch)
            when (distance) {
                1 -> {
                    if (SuggestionEngine.isNeighborSubstitution(lower, word)) neighbor.add(word)
                    else distance1.add(word)
                }
                2 -> if (distance2.size < limit) distance2.add(word)
            }
            if (neighbor.size >= limit) break
        }
        return (neighbor + distance1 + distance2)
            .take(limit)
            .map { SuggestionEngine.matchCase(typed, it) }
    }

    fun strip(
        composing: String,
        before: String,
        after: String,
        correctionsEnabled: Boolean,
    ): SuggestionStrip {
        val token = composing.ifEmpty { SuggestionEngine.lastWordForEmoji(before).orEmpty() }
        val emojis = EmojiSuggestions.glyphs(token)
        if (composing.isNotEmpty()) {
            val completions = complete(composing)
            val corrections = if (correctionsEnabled) correct(composing) else emptyList()
            return SuggestionStrip((completions + corrections).distinct().take(3), emojis)
        }
        if (correctionsEnabled) {
            val span = SuggestionEngine.wordSpan(before, after)
            if (span != null && span.word.length >= 2) {
                val nearby = similar(span.word)
                if (nearby.isNotEmpty()) {
                    return SuggestionStrip(nearby, emojis, replacesWord = true)
                }
            }
        }
        return SuggestionStrip(next(SuggestionEngine.lastWord(before).orEmpty()), emojis)
    }

    fun swipe(path: String, limit: Int = 4): List<String> {
        val keys = SuggestionEngine.collapseLetters(path)
        if (keys.length < 2) return emptyList()
        // The gesture's own sampled shape and length are the same for every
        // candidate. They used to be recomputed inside the score, so a ten
        // thousand word list resampled the user's path ten thousand times.
        val gesture = SuggestionEngine.SwipeGesture(keys)
        val scored = ArrayList<Pair<String, Float>>()
        for (rank in words.indices) {
            val compact = collapsed[rank]
            val last = collapsedLength[rank] - 1
            if (last < 1) continue
            if (!gesture.endsAreReachable(compact[0], compact[last])) continue
            if (!SuggestionEngine.isSubsequence(compact, keys)) continue
            scored.add(words[rank] to gesture.score(compact, rank))
        }
        return scored
            .sortedByDescending { it.second }
            .take(limit)
            .map { it.first }
    }

    companion object {
        /**
         * How many leading characters a prefix bucket is keyed by. Three keeps
         * the map at a few thousand entries for the shipped list while leaving
         * the average bucket small enough to walk.
         */
        private const val PREFIX_KEY_LENGTH = 3

        /** See [letterMasks]: two edits can move at most four distinct letters. */
        private const val MAX_LETTER_DIFFERENCE = 4

        private fun letterMask(word: String): Int {
            var mask = 0
            for (character in word) mask = mask or SuggestionEngine.letterBit(character)
            return mask
        }

        private fun buildPrefixIndex(words: List<String>): Map<String, IntArray> {
            val builders = HashMap<String, MutableList<Int>>()
            words.forEachIndexed { index, word ->
                val lower = word.lowercase()
                for (length in 1..minOf(PREFIX_KEY_LENGTH, lower.length)) {
                    builders.getOrPut(lower.substring(0, length)) { ArrayList() }.add(index)
                }
            }
            return builders.mapValues { (_, indices) -> indices.toIntArray() }
        }

        // Both files come from assets/keyboard/ at the repository root, merged
        // into the asset root by the sourceSets entry in app/build.gradle.kts.
        // The iOS keyboard reads the same two files.
        fun load(assets: AssetManager) = SuggestionDictionary(
            words = assets.open("en.txt").bufferedReader().readLines()
                .map { it.trim() }
                .filter { it.isNotEmpty() },
            bigrams = parseBigrams(
                assets.open("en-bigrams.txt").bufferedReader().readLines(),
            ),
        )

        fun parseBigrams(lines: List<String>): Map<String, List<String>> = buildMap {
            for (line in lines) {
                val trimmed = line.trim()
                if (trimmed.isEmpty() || trimmed.startsWith("#")) continue
                val tab = trimmed.indexOf('\t')
                if (tab <= 0) continue
                val word = trimmed.substring(0, tab)
                val continuations = trimmed.substring(tab + 1)
                    .split(',')
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                if (continuations.isNotEmpty()) put(word, continuations)
            }
        }
    }
}

internal object SuggestionEngine {
    fun lastWord(textBeforeCursor: CharSequence): String? {
        val trimmed = textBeforeCursor.trimEnd()
        if (trimmed.isEmpty()) return null
        var start = trimmed.length
        while (start > 0) {
            val character = trimmed[start - 1]
            if (!character.isLetterOrDigit() && character != '\'') break
            start--
        }
        val word = trimmed.substring(start).replace("'", "").lowercase()
        return word.takeIf { it.any(Char::isLetter) }
    }

    /** Last word even when a space or period is already sitting after it. */
    fun lastWordForEmoji(textBeforeCursor: CharSequence): String? {
        var end = textBeforeCursor.length
        while (end > 0 && !isWordChar(textBeforeCursor[end - 1])) end--
        if (end == 0) return null
        var start = end
        while (start > 0 && isWordChar(textBeforeCursor[start - 1])) start--
        val word = textBeforeCursor.subSequence(start, end).toString().replace("'", "").lowercase()
        return word.takeIf { it.any(Char::isLetter) }
    }

    internal fun matchCase(prefix: String, word: String): String = when {
        prefix.all { it.isUpperCase() } -> word.uppercase()
        prefix.first().isUpperCase() -> word.replaceFirstChar { it.uppercase() }
        else -> word
    }

    fun wordBefore(before: CharSequence): Int {
        if (before.isEmpty()) return 0
        var index = before.length
        while (index > 0 && before[index - 1].isWhitespace()) index--
        if (index == 0) return before.length
        if (isWordChar(before[index - 1])) {
            while (index > 0 && isWordChar(before[index - 1])) index--
        } else {
            while (index > 0 && !before[index - 1].isWhitespace() && !isWordChar(before[index - 1])) {
                index--
            }
        }
        return before.length - index
    }

    fun lineBefore(before: CharSequence): Int {
        if (before.isEmpty()) return 0
        if (before.last() == '\n') return 1
        val newline = before.lastIndexOf('\n')
        return before.length - (newline + 1)
    }

    internal fun isNeighborSubstitution(left: String, right: String): Boolean {
        if (left.length != right.length) return false
        var diff = -1
        for (index in left.indices) {
            if (left[index] == right[index]) continue
            if (diff >= 0) return false
            diff = index
        }
        if (diff < 0) return false
        return right[diff] in nearbyLetters(left[diff])
    }

    fun replaceableWord(before: CharSequence, after: CharSequence): WordSpan? {
        wordSpan(before, after)?.let { return it }
        val text = before.toString()
        val trimmed = text.trimEnd()
        if (trimmed.length == text.length) return null
        val span = wordSpan(trimmed, "") ?: return null
        return span.copy(beforeLength = span.beforeLength + (text.length - trimmed.length))
    }

    fun wordSpan(before: CharSequence, after: CharSequence): WordSpan? {
        var start = before.length
        while (start > 0 && isWordChar(before[start - 1])) start--
        var end = 0
        while (end < after.length && isWordChar(after[end])) end++
        if (start == before.length && end == 0) return null
        val word = buildString {
            append(before.subSequence(start, before.length))
            append(after.subSequence(0, end))
        }
        if (word.none { it.isLetter() }) return null
        return WordSpan(word, before.length - start, end)
    }

    /**
     * Three rows of the edit-distance matrix, reused across a whole scan.
     *
     * The rows are the same shape for every candidate, so allocating them per
     * word meant three `IntArray`s per dictionary entry — tens of thousands of
     * short-lived arrays per keystroke, and the garbage collection that comes
     * with them, on the thread drawing the keyboard.
     *
     * Not thread-safe, deliberately: one belongs to one scan, and sharing one
     * between scans would interleave two matrices in the same rows.
     */
    internal class EditDistanceScratch(maxRightLength: Int) {
        var previousPrevious = IntArray(maxRightLength + 1)
            private set
        var previous = IntArray(maxRightLength + 1)
            private set
        var current = IntArray(maxRightLength + 1)
            private set

        /**
         * Grows in place rather than handing back a bigger one, so a caller
         * that held onto this keeps the rows that grew.
         *
         * Returning a replacement looked equivalent and was not: `similar`
         * binds its scratch once and reuses it for a whole scan, so it would
         * have kept the undersized one and allocated a replacement per
         * candidate — the exact cost this class exists to remove, with nothing
         * failing to say so.
         */
        fun fit(columns: Int) {
            if (previous.size > columns) return
            previousPrevious = IntArray(columns + 1)
            previous = IntArray(columns + 1)
            current = IntArray(columns + 1)
        }
    }

    internal fun editDistance(left: String, right: String, max: Int): Int =
        editDistance(left, right, max, EditDistanceScratch(right.length))

    internal fun editDistance(
        left: String,
        right: String,
        max: Int,
        scratch: EditDistanceScratch,
    ): Int {
        if (left == right) return 0
        if (kotlin.math.abs(left.length - right.length) > max) return max + 1
        val columns = right.length
        scratch.fit(columns)
        var previousPrevious = scratch.previousPrevious
        var previous = scratch.previous
        var current = scratch.current
        // Only the prefix this candidate uses is reset; the tail is never read.
        for (index in 0..columns) {
            previousPrevious[index] = 0
            previous[index] = index
        }
        for (i in 1..left.length) {
            current[0] = i
            var rowMin = current[0]
            val leftChar = left[i - 1]
            for (j in 1..columns) {
                val substitution = if (leftChar == right[j - 1]) 0 else 1
                var value = minOf(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + substitution,
                )
                if (
                    i > 1 &&
                    j > 1 &&
                    leftChar == right[j - 2] &&
                    left[i - 2] == right[j - 1]
                ) {
                    value = minOf(value, previousPrevious[j - 2] + 1)
                }
                current[j] = value
                if (value < rowMin) rowMin = value
            }
            if (rowMin > max) return max + 1
            val recycled = previousPrevious
            previousPrevious = previous
            previous = current
            current = recycled
        }
        return previous[columns]
    }

    internal fun collapseLetters(path: String): String = buildString {
        for (character in path.lowercase()) {
            if (character.isLetter() && (isEmpty() || character != last())) append(character)
        }
    }

    internal fun isSubsequence(word: String, path: String): Boolean {
        var index = 0
        for (character in path) {
            if (index < word.length && character == word[index]) index++
        }
        return index == word.length
    }

    /**
     * FlorisBoard / AnySoftKeyboard compare a swipe to the ideal line through
     * the word's key centers, then rank by shape and path length. We do the
     * same on the QWERTY grid instead of taking the first dictionary hit.
     */
    /**
     * One gesture's key path, with everything that depends only on the gesture
     * worked out once.
     *
     * Scoring used to take the raw path and re-derive all of this per candidate,
     * so a ten thousand word list resampled the user's sixteen points ten
     * thousand times and rebuilt its own neighbour sets on the way in.
     */
    internal class SwipeGesture(val keys: String) {
        private val samples = samplePath(keys, SAMPLE_POINTS)
        private val length = pathLength(keys)

        /**
         * The acceptable first and last keys as letter bitmaps rather than
         * `Set<Char>`. Membership in a `Set<Char>` boxes the character, and this
         * is tested twice for every word in the list on every gesture — twenty
         * thousand boxes per swipe, for a question a shift and an and answers.
         */
        private val firstMask = letterBits(nearbyLetters(keys.first()) + keys.first())
        private val lastMask = letterBits(nearbyLetters(keys.last()) + keys.last())

        fun endsAreReachable(first: Char, last: Char): Boolean =
            letterBit(first) and firstMask != 0 && letterBit(last) and lastMask != 0

        fun score(compactWord: String, frequencyRank: Int): Float {
            val shape = shapeDistance(compactWord)
            val lengthGap = kotlin.math.abs(length - pathLength(compactWord))
            val endPenalty =
                (if (compactWord.first() == keys.first()) 0f else 0.7f) +
                    (if (compactWord.last() == keys.last()) 0f else 0.7f)
            val frequency = 1f / (1f + frequencyRank / 400f)
            return frequency * 2f - shape * 3f - lengthGap * 0.35f - endPenalty
        }

        private fun shapeDistance(word: String): Float {
            val ideal = samplePath(word, SAMPLE_POINTS)
            if (samples.isEmpty() || ideal.isEmpty()) return Float.MAX_VALUE
            var sum = 0f
            for (index in samples.indices) sum += samples[index].distanceTo(ideal[index])
            return sum / samples.size
        }
    }

    internal fun nearbyLetters(letter: Char): Set<Char> = NEARBY[letter].orEmpty()

    /** One bit per a-z letter; bit 26 stands in for everything else. */
    internal fun letterBit(letter: Char): Int {
        val offset = letter - 'a'
        return if (offset in 0..25) 1 shl offset else 1 shl 26
    }

    internal fun letterBits(letters: Iterable<Char>): Int {
        var mask = 0
        for (letter in letters) mask = mask or letterBit(letter)
        return mask
    }

    private fun pathLength(keys: String): Float {
        var length = 0f
        var previous: KeyXY? = null
        for (character in keys) {
            val point = QWERTY[character] ?: continue
            if (previous != null) length += previous.distanceTo(point)
            previous = point
        }
        return length
    }

    private fun samplePath(keys: String, count: Int): List<KeyXY> {
        val points = keys.mapNotNull { QWERTY[it] }
        if (points.isEmpty()) return emptyList()
        if (points.size == 1 || count <= 1) return List(count.coerceAtLeast(1)) { points.first() }
        val prefix = FloatArray(points.size)
        for (index in 1 until points.size) {
            prefix[index] = prefix[index - 1] + points[index - 1].distanceTo(points[index])
        }
        val total = prefix.last().coerceAtLeast(0.0001f)
        return List(count) { sample ->
            val target = total * sample / (count - 1)
            var index = 1
            while (index < prefix.lastIndex && prefix[index] < target) index++
            val start = prefix[index - 1]
            val span = (prefix[index] - start).coerceAtLeast(0.0001f)
            val t = ((target - start) / span).coerceIn(0f, 1f)
            val from = points[index - 1]
            val to = points[index]
            KeyXY(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t)
        }
    }

    private data class KeyXY(val x: Float, val y: Float) {
        fun distanceTo(other: KeyXY): Float {
            val dx = x - other.x
            val dy = y - other.y
            return kotlin.math.sqrt(dx * dx + dy * dy)
        }
    }

    private const val SAMPLE_POINTS = 16

    private val QWERTY: Map<Char, KeyXY> = buildMap {
        fun row(y: Float, startX: Float, letters: String) {
            letters.forEachIndexed { index, letter -> put(letter, KeyXY(startX + index, y)) }
        }
        row(0f, 0f, "qwertyuiop")
        row(1f, 0.5f, "asdfghjkl")
        row(2f, 1.5f, "zxcvbnm")
    }

    /**
     * Keys within reach of a mistyped one, worked out once for the whole
     * layout. Derived per call, this allocated a list and a set on every
     * distance-1 candidate the correction scan found, and twice per swipe.
     *
     * Declared after [QWERTY] because an object's properties initialize in
     * source order, and this one reads it.
     */
    private val NEARBY: Map<Char, Set<Char>> = QWERTY.mapValues { (letter, origin) ->
        QWERTY.entries
            .filter { (other, point) -> other != letter && origin.distanceTo(point) < 1.55f }
            .map { it.key }
            .toSet()
    }

    private fun isWordChar(character: Char): Boolean =
        character.isLetterOrDigit() || character == '\''
}
