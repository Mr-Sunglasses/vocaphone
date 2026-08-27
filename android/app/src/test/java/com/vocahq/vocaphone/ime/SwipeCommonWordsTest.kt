package com.vocahq.vocaphone.ime

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * What a careful swipe of a common word actually returns.
 *
 * The production matcher sees geometry, not an ideal letter string. These
 * tests lock the *model* (shape + letters-on-path + frequency), not one
 * word: an ideal trace, a fly-over of the same polyline, a colinear
 * shortcut, and a straight first→last swipe of words that are the best
 * explanation of that segment.
 */
class SwipeCommonWordsTest {

    private val words: List<String>? by lazy {
        generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "assets/keyboard/en.txt") }
            .firstOrNull(File::isFile)
            ?.readLines()
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
    }

    private fun dictionary(): SuggestionDictionary {
        val list = words
        assumeTrue("assets/keyboard is only present in the repository", list != null)
        return SuggestionDictionary(words = list!!, bigrams = emptyMap())
    }

    private val common = listOf(
        "the", "of", "and", "to", "in", "for", "is", "on", "that", "this",
        "with", "you", "it", "not", "or", "are", "from", "at", "as", "have",
        "was", "we", "will", "can", "about", "but", "our", "what", "which",
        "they", "just", "like", "some", "would", "there", "good", "go",
        "top", "hello", "when", "your", "all", "more", "if", "out", "see",
        "how", "been", "make", "should", "into", "over", "time", "get",
        "quick", "brown", "fox", "lazy", "frog",
    )

    @Test
    fun `ideal path through a common word ranks it in the strip`() {
        val dict = dictionary()
        val list = words ?: return
        val bestByEnds = LinkedHashMap<String, String>()
        for (word in list) {
            val compact = SuggestionEngine.collapseLetters(word)
            if (compact.length < 2) continue
            bestByEnds.putIfAbsent("${compact.first()}${compact.last()}", word)
        }
        val missedStrip = ArrayList<String>()
        val missedFirst = ArrayList<String>()
        for (word in common) {
            val top = dict.swipe(word, points = SwipeLayout.interpolate(word))
            if (word !in top) missedStrip.add("$word → $top")
            val compact = SuggestionEngine.collapseLetters(word)
            if (compact.length < 2) continue
            val ends = "${compact.first()}${compact.last()}"
            // Colinear with a more frequent word (our / or) shares a shape;
            // frequency then decides. The word that *owns* those ends still
            // has to come first on its own ideal path.
            if (bestByEnds[ends] == word && top.firstOrNull() != word) {
                missedFirst.add("$word → $top")
            }
        }
        assertTrue("ideal-path strip misses:\n${missedStrip.joinToString("\n")}", missedStrip.isEmpty())
        assertTrue("ideal-path first misses:\n${missedFirst.joinToString("\n")}", missedFirst.isEmpty())
    }

    @Test
    fun `a fly-over path through a common word still ranks it in the top suggestions`() {
        val dict = dictionary()
        val misses = ArrayList<String>()
        for (word in common) {
            val points = SwipeLayout.interpolate(word, stepsPerSegment = 12)
            val keys = SwipeLayout.nearestKeyString(points)
            val top = dict.swipe(keys, points = points)
            // Top four is what the strip shows. Missing the strip is the
            // failure the user feels: they swiped "with" and never saw it.
            if (word !in top) {
                misses.add("$word keys=$keys → $top")
            }
        }
        assertTrue("fly-over misses:\n${misses.joinToString("\n")}", misses.isEmpty())
    }

    @Test
    fun `shortcut swipes of common words stay in the strip`() {
        val dict = dictionary()
        val misses = ArrayList<String>()
        for (word in common) {
            val points = SwipeLayout.shortcutInterpolate(word)
            val keys = SwipeLayout.nearestKeyString(points)
            val top = dict.swipe(keys, points = points)
            if (word !in top) misses.add("$word keys=$keys → $top")
        }
        assertTrue("shortcut misses:\n${misses.joinToString("\n")}", misses.isEmpty())
    }

    @Test
    fun `a straight swipe between two keys prefers the word that best explains that segment`() {
        // Same rule for every pair: frequency plus how well the letters sit
        // on the segment. There is no two-letter "wh", so W→H is "with";
        // T→E is "the" even though "te" exists, because "the" is so common.
        val dict = dictionary()
        val cases = listOf(
            "the", "to", "of", "in", "on", "it", "or", "at", "as", "we", "if",
            "go", "with", "you", "not",
        )
        val misses = ArrayList<String>()
        for (word in cases) {
            val compact = SuggestionEngine.collapseLetters(word)
            val points = SwipeLayout.interpolate("${compact.first()}${compact.last()}")
            val keys = SwipeLayout.nearestKeyString(points)
            val top = dict.swipe(keys, points = points)
            if (top.firstOrNull() != word) misses.add("$word keys=$keys → $top")
        }
        assertTrue("straight-path misses:\n${misses.joinToString("\n")}", misses.isEmpty())
    }

    @Test
    fun `drawing a word's shape beats a more common word that only shares its ends`() {
        val dict = dictionary()
        val points = SwipeLayout.interpolate("which")
        val keys = SwipeLayout.nearestKeyString(points)
        val top = dict.swipe(keys, points = points)
        assertEquals("which keys=$keys → $top", "which", top.first())
    }

    @Test
    fun `a four-key what swipe ranks what first and keeps same-path alternatives`() {
        val dict = dictionary()
        val points = SwipeLayout.interpolate("what")
        val keys = SwipeLayout.nearestKeyString(points)
        val top = dict.swipe(keys, points = points)
        assertEquals("what keys=$keys → $top", "what", top.first())
        assertTrue("long end-sharing words in strip: $top", "wednesday" !in top && "without" !in top)
    }

    @Test
    fun `pangram words rank first on their own traces`() {
        // "jumps" is not in the shipped list; the rest of the sentence is.
        val dict = dictionary()
        val misses = ArrayList<String>()
        for (word in listOf("the", "quick", "brown", "fox", "over", "lazy", "frog")) {
            val top = dict.swipe(word, points = SwipeLayout.interpolate(word))
            if (top.firstOrNull() != word) misses.add("$word → $top")
        }
        assertTrue("pangram misses:\n${misses.joinToString("\n")}", misses.isEmpty())
    }
}
