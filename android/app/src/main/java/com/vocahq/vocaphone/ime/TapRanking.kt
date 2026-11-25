package com.vocahq.vocaphone.ime

import kotlin.math.ln

/**
 * Where the finger landed on each key of the word being typed, as offsets from
 * the key's centre in key widths (x) and key heights (y). NaN where unknown.
 *
 * Kept beside [KeyboardState.composing] rather than inside it: the reducer
 * copies the state on every key, and two fixed arrays here cost nothing per
 * keystroke. [record] follows the composing word as it grows; anything else
 * (a delete, an accent swapped in, a swipe) is realigned against the word the
 * next time it is read, keeping the taps of the prefix that still matches.
 */
internal class TapTrace(private val capacity: Int = 48) {
    private val xs = FloatArray(capacity)
    private val ys = FloatArray(capacity)
    private var length = 0
    private var word = ""

    /** A letter went out: [composing] is the word with it, tapped at ([dx], [dy]). */
    fun record(composing: String, dx: Float, dy: Float) {
        if (composing.isEmpty()) {
            clear()
            return
        }
        val prefixLength = composing.length - 1
        if (length != prefixLength || !composing.startsWith(word) || word.length != prefixLength) {
            realign(composing, prefixLength)
        }
        if (length < capacity) {
            xs[length] = dx
            ys[length] = dy
            length++
        }
        word = composing
    }

    fun clear() {
        length = 0
        word = ""
    }

    /**
     * The taps for [composing], interleaved x0, y0, x1, y1, ..., or null when
     * none of its letters has one. A copy, so it can go to another thread.
     */
    fun snapshot(composing: String): FloatArray? {
        if (composing.isEmpty() || composing.length > capacity) return null
        if (word != composing) {
            realign(composing, composing.length)
            word = composing
        }
        var known = false
        val out = FloatArray(composing.length * 2)
        for (index in 0 until composing.length) {
            out[index * 2] = xs[index]
            out[index * 2 + 1] = ys[index]
            if (!xs[index].isNaN()) known = true
        }
        return out.takeIf { known }
    }

    /** Keep the taps of the prefix [target] shares with [word]; NaN for the rest up to [count]. */
    private fun realign(target: String, count: Int) {
        var shared = 0
        val limit = minOf(word.length, length, target.length, count)
        while (shared < limit && word[shared] == target[shared]) shared++
        val end = minOf(count, capacity)
        for (index in shared until end) {
            xs[index] = Float.NaN
            ys[index] = Float.NaN
        }
        length = end
        word = target.take(end)
    }
}

/**
 * Correction ranking that knows where the finger landed.
 *
 * A typo is usually the finger landing on the edge of the key next to the one
 * it meant. For a candidate the same length as what was typed, each letter
 * that differs is scored by how much better the tap fits the candidate's key
 * than the typed one, as a Gaussian log-likelihood ratio: with `tap` the
 * offset from the typed key's centre and `d` the vector from the typed key to
 * the candidate's key, `-(|tap - d|² - |tap|²) / 2σ²`. A tap on the far right
 * of `r` makes `t` plausible; a tap in the middle of `r` makes it unlikely.
 *
 * That is added to a prior from the existing order (a neighbouring-key
 * substitution, then any one edit, then two; frequency within) and a bonus for
 * a word the bigram table predicts after the previous word.
 */
internal object TapRanking {
    const val SIGMA = 0.35f

    /** How far a candidate has to beat the typed word's own reading to rank above it. */
    const val MARGIN = 1.0f

    const val BIGRAM_BONUS = 1.0f

    /** Prior cost of each step down from neighbour substitution to two edits. */
    const val BUCKET_STEP = 1.0f

    private const val FREQUENCY_WEIGHT = 0.5f

    /** One letter can cost at most this much, so a wild tap cannot bury a word on its own. */
    private const val MAX_LETTER_COST = 8f

    internal data class Candidate(
        val word: String,
        /** 0: a neighbouring-key substitution; 1: one edit; 2: two edits. */
        val bucket: Int,
        /** Position in the frequency-ordered word list. */
        val rank: Int,
    )

    private val centers: Map<Char, Pair<Float, Float>> = buildMap {
        fun row(y: Float, startX: Float, letters: String) {
            letters.forEachIndexed { index, letter -> put(letter, (startX + index) to y) }
        }
        row(0f, 0f, "qwertyuiop")
        row(1f, 0.5f, "asdfghjkl")
        row(2f, 1.5f, "zxcvbnm")
    }

    fun spatial(typed: String, candidate: String, taps: FloatArray?): Float {
        if (taps == null || typed.length != candidate.length || isTransposition(typed, candidate)) return 0f
        var score = 0f
        val sigma2 = 2f * SIGMA * SIGMA
        for (index in typed.indices) {
            if (index * 2 + 1 >= taps.size) break
            val tx = taps[index * 2]
            val ty = taps[index * 2 + 1]
            if (tx.isNaN() || ty.isNaN()) continue
            val t = typed[index].lowercaseChar()
            val c = candidate[index].lowercaseChar()
            if (t == c) continue
            val from = centers[t] ?: continue
            val to = centers[c] ?: continue
            val dx = to.first - from.first
            val dy = to.second - from.second
            val ex = tx - dx
            val ey = ty - dy
            val contribution = -((ex * ex + ey * ey) - (tx * tx + ty * ty)) / sigma2
            score += contribution.coerceAtLeast(-MAX_LETTER_COST)
        }
        return score
    }

    fun prior(bucket: Int, rank: Int): Float =
        -BUCKET_STEP * bucket - FREQUENCY_WEIGHT * ln(1f + rank / 100f)

    fun score(typed: String, candidate: Candidate, taps: FloatArray?, predicted: Set<String>): Float =
        prior(candidate.bucket, candidate.rank) +
            spatial(typed, candidate.word, taps) +
            (if (candidate.word.lowercase() in predicted) BIGRAM_BONUS else 0f)

    /**
     * [candidates] best first. When [typedRank] is given the typed word is a
     * word too, read as typed: it is placed in the order, and a candidate goes
     * above it only by beating it by [MARGIN]. The typed word is in the
     * returned list then; callers that do not show it drop it.
     */
    fun order(
        typed: String,
        candidates: List<Candidate>,
        taps: FloatArray?,
        predicted: Set<String>,
        typedRank: Int? = null,
    ): List<String> {
        val scored = candidates
            .map { it.word to score(typed, it, taps, predicted) }
            .sortedByDescending { it.second }
        if (typedRank == null) return scored.map { it.first }
        val typedScore = prior(0, typedRank) + (if (typed.lowercase() in predicted) BIGRAM_BONUS else 0f)
        val (above, below) = scored.partition { it.second > typedScore + MARGIN }
        return above.map { it.first } + typed + below.map { it.first }
    }

    private fun isTransposition(left: String, right: String): Boolean {
        var first = -1
        var second = -1
        for (index in left.indices) {
            if (left[index] == right[index]) continue
            when {
                first < 0 -> first = index
                second < 0 -> second = index
                else -> return false
            }
        }
        return second == first + 1 && first >= 0 &&
            left[first] == right[second] && left[second] == right[first]
    }
}
