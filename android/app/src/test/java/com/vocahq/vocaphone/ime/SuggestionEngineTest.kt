package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SuggestionEngineTest {

    private val dictionary = SuggestionDictionary(
        words = listOf("hello", "help", "held", "the", "there", "their", "book"),
        bigrams = mapOf(
            "the" to listOf("first", "same", "other"),
            "see" to listOf("you", "the"),
        ),
    )

    @Test
    fun `completions follow frequency order and skip the exact prefix`() {
        assertEquals(listOf("hello", "help", "held"), dictionary.complete("hel"))
        assertEquals(listOf("Hello", "Help", "Held"), dictionary.complete("Hel"))
        assertEquals(listOf("HELLO", "HELP", "HELD"), dictionary.complete("HEL"))
        assertTrue(dictionary.complete("zzz").isEmpty())
    }

    @Test
    fun `next word uses the last token before the cursor`() {
        assertEquals("world", SuggestionEngine.lastWord("hello world"))
        assertEquals("world", SuggestionEngine.lastWord("hello world "))
        assertEquals("dont", SuggestionEngine.lastWord("I don't"))
        assertEquals(listOf("you", "the"), dictionary.next("see"))
        assertTrue(dictionary.next("xyz").isEmpty())
    }

    @Test
    fun `corrections prefer nearby dictionary words`() {
        assertEquals(listOf("hello"), dictionary.correct("helllo"))
        assertEquals(listOf("the"), dictionary.correct("teh"))
        assertTrue(dictionary.correct("hello").isEmpty())
        assertEquals(listOf("Hello"), dictionary.correct("Helllo"))
    }

    @Test
    fun `word span covers the token around the cursor`() {
        val span = SuggestionEngine.wordSpan("say hel", "lo there")
        assertEquals("hello", span?.word)
        assertEquals(3, span?.beforeLength)
        assertEquals(2, span?.afterLength)
    }

    @Test
    fun `strip offers corrections for a misspelled committed word`() {
        val strip = dictionary.strip(
            composing = "",
            before = "helllo",
            after = "",
            correctionsEnabled = true,
        )
        assertEquals("hello", strip.words.first())
        assertTrue(strip.replacesWord)
    }

    @Test
    fun `similar offers nearby words even when the typed word is known`() {
        assertTrue(dictionary.correct("hello").isEmpty())
        val nearby = dictionary.similar("hello")
        assertTrue(nearby.contains("help") || nearby.contains("held"))
        assertTrue("hello" !in nearby)
    }

    @Test
    fun `strip offers nearby replacements when the cursor is in a known word`() {
        val strip = dictionary.strip(
            composing = "",
            before = "hello",
            after = "",
            correctionsEnabled = true,
        )
        assertTrue(strip.replacesWord)
        assertTrue(strip.words.any { it == "help" || it == "held" })
        assertTrue("hello" !in strip.words)
    }

    @Test
    fun `strip skips replacements when corrections are off`() {
        val strip = dictionary.strip(
            composing = "",
            before = "hello",
            after = "",
            correctionsEnabled = false,
        )
        assertTrue(strip.words.isEmpty())
        assertTrue(!strip.replacesWord)
    }

    @Test
    fun `strip keeps next-word guesses after a space`() {
        val strip = dictionary.strip(
            composing = "",
            before = "the ",
            after = "",
            correctionsEnabled = true,
        )
        assertEquals(listOf("first", "same", "other"), strip.words)
        assertTrue(!strip.replacesWord)
    }

    @Test
    fun `word before deletes the previous token and its trailing space`() {
        assertEquals(5, SuggestionEngine.wordBefore("hello world"))
        assertEquals(6, SuggestionEngine.wordBefore("hello world "))
        assertEquals(2, SuggestionEngine.wordBefore("hello. "))
        assertEquals(0, SuggestionEngine.wordBefore(""))
        assertEquals(3, SuggestionEngine.wordBefore("   "))
    }

    @Test
    fun `line before deletes back to the previous newline`() {
        assertEquals(1, SuggestionEngine.lineBefore("a\nb\nc"))
        assertEquals(1, SuggestionEngine.lineBefore("a\nb\n"))
        assertEquals(5, SuggestionEngine.lineBefore("hello"))
        assertEquals(0, SuggestionEngine.lineBefore(""))
    }

    @Test
    fun `swipe matches a path across letter keys`() {
        assertEquals(listOf("the"), dictionary.swipe("the"))
        assertEquals(listOf("the"), dictionary.swipe("tghe"))
        assertEquals(listOf("hello"), dictionary.swipe("hjkello"))
        assertEquals(listOf("hello"), dictionary.swipe("helo"))
        assertEquals(listOf("book"), dictionary.swipe("bok"))
        assertTrue(dictionary.swipe("qz").isEmpty())
        assertTrue(dictionary.swipe("h").isEmpty())
    }

    @Test
    fun `english list picks some not see on an s-o-m-e swipe`() {
        val file = java.io.File("src/main/assets/suggestions/en.txt")
        org.junit.Assume.assumeTrue(file.exists())
        val dict = SuggestionDictionary(
            words = file.readLines().map { it.trim() }.filter { it.isNotEmpty() },
            bigrams = emptyMap(),
        )
        assertEquals("some", dict.swipe("sdfghjklomnhytre").first())
        assertEquals("hello", dict.swipe("hjkello").first())
        assertEquals("the", dict.swipe("tghe").first())
    }

    @Test
    fun `swipe prefers the word whose key path matches the gesture`() {
        val words = SuggestionDictionary(
            words = listOf("see", "she", "same", "some", "store", "case"),
            bigrams = emptyMap(),
        )
        // S → O → M → E crosses the home row, then down to M, then up to E.
        // "see" is earlier in the list and is a subsequence, but the shape is "some".
        assertEquals("some", words.swipe("sdfghjklomnhytre").first())
        assertEquals("some", words.swipe("sertoiuytrewmne").first())
    }

    @Test
    fun `replaceable word includes a trailing space after a swipe`() {
        val span = SuggestionEngine.replaceableWord("hello ", "")
        assertEquals("hello", span?.word)
        assertEquals(6, span?.beforeLength)
        assertEquals(0, span?.afterLength)
    }
}
