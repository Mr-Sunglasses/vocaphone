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
        val words = listOf("you", "the")
        assertEquals(emptyList<String>(), KeyboardChrome.suggestionsForStrip(words, startedTyping = false))
        assertEquals(words, KeyboardChrome.suggestionsForStrip(words, startedTyping = true))
    }
}
