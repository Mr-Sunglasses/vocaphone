package com.vocahq.vocaphone.writing

/**
 * Writing check's spelling: whether a word is in the dictionary, and if not,
 * the word the user most likely meant. Mirrors `WritingSpelling.swift`; both
 * are tested against `assets/grammar/writing_fixtures.json`.
 *
 * The dictionary is `assets/keyboard/en-spelling.txt` (SCOWL size 60, US,
 * British, Canadian and Australian spellings; see
 * `tools/writing-rules/build_spelling.py`), ranked by `en.txt`, the
 * keyboard's frequency list. Words are kept as sorted byte runs, one array per
 * length, so the whole dictionary costs about a megabyte and a lookup is a
 * binary search; nothing here allocates per word but the answer.
 *
 * A candidate is any dictionary word within two edits (one for words shorter
 * than [LONG]), scored by a keyboard-aware Damerau–Levenshtein distance and
 * by how common the word is. Everything is integer arithmetic, so both
 * platforms rank the same words the same way.
 */
class WritingSpelling private constructor(
    /** Lower-case words that may be suggested, by length: sorted, fixed-width runs. */
    private val words: Array<ByteArray>,
    /** Each word's frequency cost, in the same order as [words]. */
    private val costs: Array<ByteArray>,
    /** Words accepted but never suggested (names, chat words), lower case, by length. */
    private val accepted: Array<ByteArray>,
    /** Names accepted only with their capitals, by length. */
    private val proper: Array<ByteArray>,
) {
    /** What [suggest] found: the word, how far it is, and whether it is clearly the one. */
    data class Guess(val word: String, val edits: Int, val score: Int, val sure: Boolean)

    /** Whether [word], exactly as typed (letters and apostrophes, ASCII), is spelled right. */
    fun isKnown(word: String): Boolean {
        val bytes = ascii(word) ?: return true
        if (contains(proper, bytes)) return true
        val lower = lower(bytes)
        if (contains(words, lower) || contains(accepted, lower)) return true
        // A name typed in lower case ("facebook", "paris"), from four letters on.
        if (lower.size >= 4 && containsLowered(proper, lower)) return true
        // A possessive: "dog's", "James's".
        if (lower.size > 2 && lower[lower.size - 2] == APOSTROPHE && lower[lower.size - 1] == 's'.code.toByte()) {
            val stem = word.substring(0, word.length - 2)
            return stem.isNotEmpty() && isKnown(stem)
        }
        return false
    }

    /**
     * The dictionary word [word] most likely meant, or null when none is
     * close enough. [word] is lower case ASCII letters.
     */
    fun suggest(word: String): Guess? {
        val typed = ascii(word) ?: return null
        val n = typed.size
        if (n < MIN_LENGTH || n > MAX_LENGTH) return null
        val maxEdits = if (n >= LONG) 2 else 1
        val limit = maxEdits * EDIT
        var best: Guess? = null
        var bestScore = Int.MAX_VALUE
        var bestCost = 0
        var secondScore = Int.MAX_VALUE
        val row0 = IntArray(MAX_LENGTH + 3)
        val row1 = IntArray(MAX_LENGTH + 3)
        val row2 = IntArray(MAX_LENGTH + 3)
        val starts = firstLetters(typed)
        for (length in maxOf(1, n - maxEdits)..minOf(MAX_LENGTH, n + maxEdits)) {
            val bucket = words[length]
            val count = bucket.size / length
            // The bucket is sorted, so each first letter is one run of it.
            for (first in starts) {
                val from = lowerBound(bucket, length, count, first)
                val to = lowerBound(bucket, length, count, (first + 1).toByte())
                for (k in from until to) {
                    val at = k * length
                    val cost = distance(typed, bucket, at, length, limit, row0, row1, row2)
                    if (cost > limit) continue
                    val frequency = costs[length][k].toInt()
                    val score = cost * DISTANCE_WEIGHT + frequency
                    if (score < bestScore || (score == bestScore && frequency < bestCost)) {
                        if (best != null) secondScore = minOf(secondScore, bestScore)
                        bestScore = score
                        bestCost = frequency
                        best = Guess(String(bucket, at, length, Charsets.US_ASCII), (cost + EDIT - 1) / EDIT, score, false)
                    } else if (score < secondScore) {
                        secondScore = score
                    }
                }
            }
        }
        val found = best ?: return null
        return found.copy(sure = found.edits == 1 && secondScore - bestScore >= SURE_MARGIN)
    }

    // ── distance ─────────────────────────────────────────────────────────

    /**
     * The first letters a meant word may have: most slips keep the first
     * letter, swap it with the second, or hit a key beside it. Words starting
     * any other way are not looked at, which is most of the speed. In
     * alphabetical order, so both platforms meet ties the same way.
     */
    private fun firstLetters(typed: ByteArray): ByteArray {
        val set = java.util.TreeSet<Int>()
        set.add(typed[0].toInt())
        if (typed.size > 1) set.add(typed[1].toInt())
        for (c in 'a'.code..'z'.code) if (adjacent(c.toByte(), typed[0])) set.add(c)
        return ByteArray(set.size).also { out -> set.forEachIndexed { i, c -> out[i] = c.toByte() } }
    }

    /** The first word in [bucket] (of [count] words of [length]) whose first letter is at least [first]. */
    private fun lowerBound(bucket: ByteArray, length: Int, count: Int, first: Byte): Int {
        var lo = 0
        var hi = count
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if ((bucket[mid * length].toInt() and 0xFF) < (first.toInt() and 0xFF)) lo = mid + 1 else hi = mid
        }
        return lo
    }

    /**
     * Weighted optimal-string-alignment distance from [a] (as typed) to the
     * word at [at] in [b], in tenths of an edit, or anything above [limit]
     * once it cannot come back under it. A swapped pair costs [TRANSPOSE], a
     * neighbouring key [NEIGHBOUR], two vowels [VOWELS], a letter typed twice
     * or once where it is doubled [DOUBLE], anything else [EDIT].
     */
    private fun distance(a: ByteArray, b: ByteArray, at: Int, m: Int, limit: Int, r0: IntArray, r1: IntArray, r2: IntArray): Int {
        val n = a.size
        // r2: row i - 2, r1: row i - 1, r0: row i; all over j in 0..m.
        var prev2 = r2
        var prev = r1
        var cur = r0
        prev[0] = 0
        for (j in 1..m) prev[j] = prev[j - 1] + insertCost(b, at, j)
        for (i in 1..n) {
            cur[0] = prev[0] + deleteCost(a, i)
            var rowMin = cur[0]
            for (j in 1..m) {
                val x = a[i - 1]
                val y = b[at + j - 1]
                var d = minOf(prev[j] + deleteCost(a, i), cur[j - 1] + insertCost(b, at, j))
                d = minOf(d, prev[j - 1] + substituteCost(x, y))
                if (i > 1 && j > 1 && x == b[at + j - 2] && a[i - 2] == y && x != y) d = minOf(d, prev2[j - 2] + TRANSPOSE)
                cur[j] = d
                if (d < rowMin) rowMin = d
            }
            if (rowMin > limit) return limit + 1
            val t = prev2
            prev2 = prev
            prev = cur
            cur = t
        }
        return prev[m]
    }

    /** Dropping typed letter [i] (1-based): cheap when it repeats the one before. */
    private fun deleteCost(a: ByteArray, i: Int) = if (i > 1 && a[i - 1] == a[i - 2]) DOUBLE else EDIT

    /** Adding the word's letter [j] (1-based): cheap when it doubles the one before. */
    private fun insertCost(b: ByteArray, at: Int, j: Int) = if (j > 1 && b[at + j - 1] == b[at + j - 2]) DOUBLE else EDIT

    private fun substituteCost(x: Byte, y: Byte): Int = when {
        x == y -> 0
        adjacent(x, y) -> NEIGHBOUR
        isVowel(x) && isVowel(y) -> VOWELS
        else -> EDIT
    }

    // ── lookup ───────────────────────────────────────────────────────────

    private fun contains(table: Array<ByteArray>, word: ByteArray): Boolean {
        val n = word.size
        if (n == 0 || n >= table.size) return false
        val bucket = table[n]
        var lo = 0
        var hi = bucket.size / n - 1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            val c = compare(bucket, mid * n, word)
            when {
                c < 0 -> lo = mid + 1
                c > 0 -> hi = mid - 1
                else -> return true
            }
        }
        return false
    }

    /** Whether some word in [table] is [lower] once lowered: a scan, but only of names of that length. */
    private fun containsLowered(table: Array<ByteArray>, lower: ByteArray): Boolean {
        val n = lower.size
        if (n >= table.size) return false
        val bucket = table[n]
        var at = 0
        while (at < bucket.size) {
            var same = true
            for (k in 0 until n) {
                if (lowerByte(bucket[at + k]) != lower[k]) {
                    same = false
                    break
                }
            }
            if (same) return true
            at += n
        }
        return false
    }

    private fun compare(bucket: ByteArray, at: Int, word: ByteArray): Int {
        for (k in word.indices) {
            val d = (bucket[at + k].toInt() and 0xFF) - (word[k].toInt() and 0xFF)
            if (d != 0) return d
        }
        return 0
    }

    companion object {
        const val EDIT = 10
        const val NEIGHBOUR = 7
        const val VOWELS = 8
        const val DOUBLE = 5
        const val TRANSPOSE = 6
        /** An edit counts this many times a frequency step: spelling comes before popularity. */
        const val DISTANCE_WEIGHT = 3
        /** How far ahead the best guess must be to be sure: accepted with "Accept all". */
        const val SURE_MARGIN = 8
        /** From this length a word may be two edits from what was meant. */
        const val LONG = 6
        const val MIN_LENGTH = 3
        const val MAX_LENGTH = 24
        private const val APOSTROPHE = '\''.code.toByte()

        /** The rank a word outside `en.txt` takes, by the SCOWL size it is in. */
        private val SECTION_RANK = mapOf("35" to 12_000, "40" to 25_000, "50" to 50_000, "60" to 90_000)

        /** How much rarer than "the" a word is: about twice log₂ of its rank, in whole steps. */
        fun frequencyCost(rank: Int): Int {
            val square = rank.toLong() * rank
            return 63 - java.lang.Long.numberOfLeadingZeros(square)
        }

        /**
         * Builds the dictionary from `en-spelling.txt` and `en.txt`. Takes
         * tens of milliseconds: callers build one off the main thread and keep it.
         */
        fun parse(spelling: String, frequency: String): WritingSpelling {
            val rank = HashMap<String, Int>()
            var r = 0
            for (line in frequency.lineSequence()) {
                val w = line.trim()
                if (w.isNotEmpty() && w !in rank) rank[w] = ++r
            }
            val suggestable = Array(MAX_LENGTH + 1) { ArrayList<Pair<ByteArray, Int>>() }
            val acceptedLists = Array(MAX_LENGTH + 1) { ArrayList<ByteArray>() }
            val properLists = Array(MAX_LENGTH + 1) { ArrayList<ByteArray>() }
            var section = ""
            for (raw in spelling.lineSequence()) {
                val line = raw.trim()
                if (line.isEmpty() || line.startsWith("#")) continue
                if (line.startsWith("@")) {
                    section = line.substring(1)
                    continue
                }
                val bytes = ascii(line) ?: continue
                if (bytes.size > MAX_LENGTH) continue
                when (section) {
                    "proper" -> properLists[bytes.size].add(bytes)
                    "accept" -> acceptedLists[bytes.size].add(bytes)
                    else -> {
                        val base = SECTION_RANK[section] ?: continue
                        suggestable[bytes.size].add(bytes to frequencyCost(rank[line] ?: base))
                    }
                }
            }
            val comparator = Comparator<ByteArray> { x, y ->
                for (k in x.indices) {
                    val d = (x[k].toInt() and 0xFF) - (y[k].toInt() and 0xFF)
                    if (d != 0) return@Comparator d
                }
                0
            }
            val words = Array(MAX_LENGTH + 1) { n ->
                suggestable[n].sortWith { x, y -> comparator.compare(x.first, y.first) }
                pack(suggestable[n].map { it.first }, n)
            }
            val costs = Array(MAX_LENGTH + 1) { n -> ByteArray(suggestable[n].size) { suggestable[n][it].second.toByte() } }
            val accepted = Array(MAX_LENGTH + 1) { n -> pack(acceptedLists[n].sortedWith(comparator), n) }
            val proper = Array(MAX_LENGTH + 1) { n -> pack(properLists[n].sortedWith(comparator), n) }
            return WritingSpelling(words, costs, accepted, proper)
        }

        private fun pack(list: List<ByteArray>, n: Int): ByteArray {
            val out = ByteArray(list.size * n)
            list.forEachIndexed { i, w -> w.copyInto(out, i * n) }
            return out
        }

        /** [word] as ASCII bytes, curly apostrophes straightened; null if it has anything else. */
        internal fun ascii(word: String): ByteArray? {
            val out = ByteArray(word.length)
            for (i in word.indices) {
                val c = if (word[i] == '’') '\'' else word[i]
                if (c.code > 127) return null
                out[i] = c.code.toByte()
            }
            return out
        }

        private fun lower(bytes: ByteArray) = ByteArray(bytes.size) { lowerByte(bytes[it]) }

        private fun lowerByte(b: Byte): Byte = if (b in 'A'.code.toByte()..'Z'.code.toByte()) (b + 32).toByte() else b

        private fun isVowel(b: Byte) = b == 'a'.code.toByte() || b == 'e'.code.toByte() || b == 'i'.code.toByte() ||
            b == 'o'.code.toByte() || b == 'u'.code.toByte()

        private val ROWS = listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")

        /** QWERTY neighbours, staggered: "s" touches "a", "d", "w", "e", "z" and "x". */
        private val NEIGHBOURS: Array<BooleanArray> = Array(128) { BooleanArray(128) }.also { table ->
            fun link(a: Char, b: Char) {
                table[a.code][b.code] = true
                table[b.code][a.code] = true
            }
            ROWS.forEachIndexed { r, row ->
                row.forEachIndexed { k, c ->
                    if (k + 1 < row.length) link(c, row[k + 1])
                    if (r + 1 < ROWS.size) {
                        val below = ROWS[r + 1]
                        if (k - 1 in below.indices) link(c, below[k - 1])
                        if (k in below.indices) link(c, below[k])
                    }
                }
            }
        }

        private fun adjacent(x: Byte, y: Byte): Boolean = x >= 0 && y >= 0 && NEIGHBOURS[x.toInt()][y.toInt()]
    }
}
