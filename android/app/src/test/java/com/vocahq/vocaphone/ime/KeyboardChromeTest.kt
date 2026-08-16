package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardChromeTest {

    private val clip = ClipboardChip(preview = "Hello", fullText = "Hello")

    @Test
    fun `empty field is not typing`() {
        assertFalse(KeyboardChrome.startedTyping("", ""))
        assertFalse(KeyboardChrome.startedTyping("", "   "))
    }

    @Test
    fun `composing or committed text counts as typing`() {
        assertTrue(KeyboardChrome.startedTyping("th", ""))
        assertTrue(KeyboardChrome.startedTyping("", "Hello there, how are"))
    }

    @Test
    fun `clipboard stays until the clip is used`() {
        assertEquals(clip, KeyboardChrome.clipboardForStrip(clip))
        assertNull(KeyboardChrome.clipboardForStrip(null))
        assertNull(KeyboardChrome.clipboardForStrip(clip, alreadyPasted = true))
    }

    @Test
    fun `suggestions only show after typing starts`() {
        val words = listOf(SuggestionItem("you"), SuggestionItem("the"))
        assertEquals(emptyList<SuggestionItem>(), KeyboardChrome.suggestionsForStrip(words, startedTyping = false))
        assertEquals(words, KeyboardChrome.suggestionsForStrip(words, startedTyping = true))
    }

    @Test
    fun `a tapped completion keeps composing so commitText can replace it`() {
        assertFalse(
            KeyboardChrome.suggestionReplacesWord(
                composing = "hel",
                swipeChoicesActive = false,
                stripReplacesWord = false,
            ),
        )
        assertFalse(
            KeyboardChrome.suggestionReplacesWord(
                composing = "hel",
                swipeChoicesActive = true,
                stripReplacesWord = true,
            ),
        )
        assertTrue(
            KeyboardChrome.suggestionReplacesWord(
                composing = "",
                swipeChoicesActive = true,
                stripReplacesWord = false,
            ),
        )
        assertTrue(
            KeyboardChrome.suggestionReplacesWord(
                composing = "",
                swipeChoicesActive = false,
                stripReplacesWord = true,
            ),
        )
        assertFalse(
            KeyboardChrome.suggestionReplacesWord(
                composing = "",
                swipeChoicesActive = false,
                stripReplacesWord = false,
            ),
        )
    }

    @Test
    fun `swipe word stays armed only after the word and its trailing space`() {
        assertTrue(KeyboardChrome.swipeWordArmed("hello", "hello ", ""))
        assertTrue(KeyboardChrome.swipeWordArmed("Hello", "hello ", ""))
        assertFalse(KeyboardChrome.swipeWordArmed("hello", "hello", ""))
        assertFalse(KeyboardChrome.swipeWordArmed("hello", "hel", "lo "))
        assertFalse(KeyboardChrome.swipeWordArmed("hello", "hello ", "there"))
        assertFalse(KeyboardChrome.swipeWordArmed("hello", "other ", ""))
        assertFalse(KeyboardChrome.swipeWordArmed(null, "hello ", ""))
    }

    @Test
    fun `swipe alternatives drop the committed word and fill from similar`() {
        assertEquals(
            listOf("ate", "age", "ace"),
            KeyboardChrome.swipeAlternatives(
                committed = "are",
                swipeMatches = listOf("are", "ate"),
                similar = listOf("are", "age", "ace", "are"),
            ),
        )
    }
}
