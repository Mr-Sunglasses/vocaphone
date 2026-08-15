package com.vocahq.vocaphone.ime

import android.content.res.AssetManager

internal class SuggestionDictionary(
    private val words: List<String>,
    private val bigrams: Map<String, List<String>>,
) {
    private val known = words.toHashSet()

    fun isKnown(word: String): Boolean = known.contains(word.lowercase())

    fun complete(prefix: String, limit: Int = 3): List<String> {
        if (prefix.isEmpty()) return emptyList()
        val lower = prefix.lowercase()
        return words.asSequence()
            .filter { it.startsWith(lower) && it.length > lower.length }
            .take(limit)
            .map { SuggestionEngine.matchCase(prefix, it) }
            .toList()
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
        for (word in words) {
            if (word == lower || word.length !in minLen..maxLen) continue
            val distance = SuggestionEngine.editDistance(lower, word, max = 2)
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
        if (composing.isNotEmpty()) {
            val completions = complete(composing)
            val corrections = if (correctionsEnabled) correct(composing) else emptyList()
            return SuggestionStrip((completions + corrections).distinct().take(3))
        }
        if (correctionsEnabled) {
            val span = SuggestionEngine.wordSpan(before, after)
            if (span != null && span.word.length >= 2) {
                val nearby = similar(span.word)
                if (nearby.isNotEmpty()) {
                    return SuggestionStrip(nearby, replacesWord = true)
                }
            }
        }
        return SuggestionStrip(next(SuggestionEngine.lastWord(before).orEmpty()))
    }

    fun swipe(path: String, limit: Int = 4): List<String> {
        val keys = SuggestionEngine.collapseLetters(path)
        if (keys.length < 2) return emptyList()
        val firstKeys = SuggestionEngine.nearbyLetters(keys.first()) + keys.first()
        val lastKeys = SuggestionEngine.nearbyLetters(keys.last()) + keys.last()
        return words.asSequence()
            .mapIndexedNotNull { rank, word ->
                val compact = SuggestionEngine.collapseLetters(word)
                if (compact.length < 2) return@mapIndexedNotNull null
                if (compact.first() !in firstKeys || compact.last() !in lastKeys) {
                    return@mapIndexedNotNull null
                }
                if (!SuggestionEngine.isSubsequence(compact, keys)) return@mapIndexedNotNull null
                word to SuggestionEngine.swipeScore(keys, compact, rank)
            }
            .sortedByDescending { it.second }
            .take(limit)
            .map { it.first }
            .toList()
    }

    companion object {
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

    internal fun editDistance(left: String, right: String, max: Int): Int {
        if (left == right) return 0
        if (kotlin.math.abs(left.length - right.length) > max) return max + 1
        val columns = right.length
        var previousPrevious = IntArray(columns + 1)
        var previous = IntArray(columns + 1) { it }
        var current = IntArray(columns + 1)
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
    internal fun swipeScore(path: String, compactWord: String, frequencyRank: Int): Float {
        val shape = shapeDistance(path, compactWord)
        val lengthGap = kotlin.math.abs(pathLength(path) - pathLength(compactWord))
        val endPenalty =
            (if (compactWord.first() == path.first()) 0f else 0.7f) +
                (if (compactWord.last() == path.last()) 0f else 0.7f)
        val frequency = 1f / (1f + frequencyRank / 400f)
        return frequency * 2f - shape * 3f - lengthGap * 0.35f - endPenalty
    }

    internal fun nearbyLetters(letter: Char): Set<Char> {
        val origin = QWERTY[letter] ?: return emptySet()
        return QWERTY.mapNotNull { (other, point) ->
            other.takeIf { it != letter && origin.distanceTo(point) < 1.55f }
        }.toSet()
    }

    internal fun shapeDistance(userPath: String, word: String): Float {
        val user = samplePath(userPath, SAMPLE_POINTS)
        val ideal = samplePath(word, SAMPLE_POINTS)
        if (user.isEmpty() || ideal.isEmpty()) return Float.MAX_VALUE
        var sum = 0f
        for (index in user.indices) sum += user[index].distanceTo(ideal[index])
        return sum / user.size
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

    private fun isWordChar(character: Char): Boolean =
        character.isLetterOrDigit() || character == '\''
}
