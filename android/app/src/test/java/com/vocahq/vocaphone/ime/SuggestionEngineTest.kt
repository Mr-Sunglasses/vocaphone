package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SuggestionEngineTest {

    private val dictionary = SuggestionDictionary(
        words = listOf("hello", "help", "held", "the", "there", "their"),
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
}
