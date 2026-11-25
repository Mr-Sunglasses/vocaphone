package com.vocahq.vocaphone.ime

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TapRankingTest {
    private val dictionary = SuggestionDictionary(
        words = listOf("the", "he", "rye"),
        bigrams = emptyMap(),
    )

    private fun taps(vararg offsets: Pair<Float, Float>) =
        FloatArray(offsets.size * 2) { if (it % 2 == 0) offsets[it / 2].first else offsets[it / 2].second }

    @Test
    fun `an r tapped on its right edge reads as t`() {
        val farRight = taps(0.45f to 0f, 0f to 0f, 0f to 0f)
        assertEquals("the", dictionary.similar("rhe", taps = farRight).first())
    }

    @Test
    fun `an r tapped in its middle does not read as t`() {
        val centred = taps(0f to 0f, 0f to 0f, 0f to 0f)
        val ranked = dictionary.similar("rhe", taps = centred)
        assertTrue(ranked.first() != "the")
        assertTrue("the" in ranked)
    }

    @Test
    fun `without taps the order is the frequency and neighbour order it was`() {
        assertEquals(listOf("the", "rye", "he"), dictionary.similar("rhe"))
    }

    @Test
    fun `the spatial score is a likelihood ratio in key units`() {
        // Centred on r, aiming for t one key right: -(1 - 0) / (2 * 0.35^2).
        assertEquals(-4.08f, TapRanking.spatial("r", "t", taps(0f to 0f)), 0.01f)
        assertEquals(-0.41f, TapRanking.spatial("r", "t", taps(0.45f to 0f)), 0.01f)
        // The same letter costs nothing, an unknown tap nothing, a transposition nothing.
        assertEquals(0f, TapRanking.spatial("r", "r", taps(0.3f to 0.2f)), 0f)
        assertEquals(0f, TapRanking.spatial("r", "t", taps(Float.NaN to Float.NaN)), 0f)
        assertEquals(0f, TapRanking.spatial("teh", "the", taps(0f to 0f, 0f to 0f, 0f to 0f)), 0f)
        assertEquals(0f, TapRanking.spatial("rhe", "he", taps(0f to 0f, 0f to 0f, 0f to 0f)), 0f)
    }

    @Test
    fun `a predicted word gets the bigram bonus`() {
        val candidates = listOf(
            TapRanking.Candidate("cat", 1, 10),
            TapRanking.Candidate("car", 1, 12),
        )
        assertEquals(listOf("cat", "car"), TapRanking.order("cax", candidates, null, emptySet()))
        assertEquals(listOf("car", "cat"), TapRanking.order("cax", candidates, null, setOf("car")))
    }

    @Test
    fun `a candidate has to beat a real typed word by a margin`() {
        val edge = taps(0.45f to 0f, 0f to 0f, 0f to 0f)
        val tat = listOf(TapRanking.Candidate("tat", 0, 500))
        assertEquals(listOf("rat", "tat"), TapRanking.order("rat", tat, edge, emptySet(), typedRank = 10))
        assertEquals(listOf("tat"), TapRanking.order("rat", tat, edge, emptySet()))
    }

    @Test
    fun `the trace follows the composing word`() {
        val trace = TapTrace()
        trace.record("r", 0.4f, 0.1f)
        trace.record("rh", 0f, 0f)
        trace.record("rhe", -0.2f, 0.3f)
        assertArrayEquals(floatArrayOf(0.4f, 0.1f, 0f, 0f, -0.2f, 0.3f), trace.snapshot("rhe"), 0f)
        // A delete keeps the prefix's taps.
        assertArrayEquals(floatArrayOf(0.4f, 0.1f, 0f, 0f), trace.snapshot("rh"), 0f)
        trace.record("rhy", 0.1f, 0.1f)
        assertArrayEquals(floatArrayOf(0.4f, 0.1f, 0f, 0f, 0.1f, 0.1f), trace.snapshot("rhy"), 0f)
        // An accent swapped in for the last letter has no tap of its own.
        val swapped = trace.snapshot("rhý")!!
        assertTrue(swapped[4].isNaN())
        // A word the taps know nothing about has none.
        assertNull(trace.snapshot("xyz"))
        trace.clear()
        assertNull(trace.snapshot("rh"))
    }
}
