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
        assertEquals(clip, KeyboardChrome.clipboardForStrip(clip, startedTyping = false))
        assertNull(KeyboardChrome.clipboardForStrip(null, startedTyping = false))
        assertNull(
            KeyboardChrome.clipboardForStrip(clip, startedTyping = false, alreadyPasted = true),
        )
    }

    /**
     * Hiding the IME re-reads the same primary clip. A dismissed chip must stay
     * down until a different copy, not come back on the next app.
     */
    @Test
    fun `a dismissed clip stays hidden until a different copy`() {
        assertTrue(KeyboardChrome.offersClipboardChip("hello", ignoredText = null, chipEnabled = true))
        assertFalse(
            KeyboardChrome.offersClipboardChip("hello", ignoredText = "hello", chipEnabled = true),
        )
        assertTrue(
            KeyboardChrome.offersClipboardChip("new copy", ignoredText = "hello", chipEnabled = true),
        )
        assertFalse(KeyboardChrome.offersClipboardChip(null, ignoredText = null, chipEnabled = true))
        assertFalse(KeyboardChrome.offersClipboardChip("", ignoredText = null, chipEnabled = true))
        assertFalse(
            KeyboardChrome.offersClipboardChip("hello", ignoredText = null, chipEnabled = false),
        )
    }

    /**
     * The regression. `DictationBar` renders the clip chip and the suggestion
     * strip into the same row and reaches the clipboard branch first, so a chip
     * that outlives the empty field sits where the word suggestions belong for
     * the rest of the sentence — copy something, start typing, and the strip
     * never shows a word again.
     */
    @Test
    fun `clipboard yields the strip once typing starts`() {
        assertNull(KeyboardChrome.clipboardForStrip(clip, startedTyping = true))
    }

    /**
     * The two halves of the row have to be mutually exclusive at every point,
     * not merely at the two ends: whatever the field contains, exactly one of
     * them may claim it.
     */
    @Test
    fun `the clip chip and the suggestions never both claim the row`() {
        val words = listOf(SuggestionItem("you"), SuggestionItem("the"))
        listOf(false, true).forEach { typing ->
            listOf(false, true).forEach { swipe ->
                val chip = KeyboardChrome.clipboardForStrip(
                    clip,
                    startedTyping = typing,
                    swipeChoicesActive = swipe,
                )
                val strip = if (swipe) {
                    words
                } else {
                    KeyboardChrome.suggestionsForStrip(words, startedTyping = typing)
                }
                assertFalse(
                    "the clip chip and ${strip.size} suggestions both claimed the row " +
                        "with startedTyping=$typing swipeChoicesActive=$swipe",
                    chip != null && strip.isNotEmpty(),
                )
            }
        }
    }

    @Test
    fun `json clips are named instead of dumping the first keys`() {
        assertEquals(
            "Copied JSON",
            KeyboardChrome.clipboardPreview("""{"timestamp": "2026-08-20"}"""),
        )
        assertEquals(
            "Copied JSON",
            KeyboardChrome.clipboardPreview("[\n  1, 2\n]"),
        )
        assertEquals("hello there everyone!", KeyboardChrome.clipboardPreview("hello there everyone!"))
    }

    @Test
    fun `an armed swipe word is always typing, so the chip is already gone`() {
        val before = "the quick "
        assertTrue(KeyboardChrome.swipeWordArmed("quick", before, ""))
        assertTrue(KeyboardChrome.startedTyping(composing = "", textBeforeCursor = before))
        assertNull(
            KeyboardChrome.clipboardForStrip(
                clip,
                startedTyping = KeyboardChrome.startedTyping("", before),
            ),
        )
    }

    /**
     * Right after a swipe on an empty field, composing is cleared and
     * `editorText` is still the pre-commit snapshot for up to 50ms. The
     * alternatives are already filled; `startedTyping` and `swipeWordArmed`
     * are not. The chip has to yield on the choices themselves.
     */
    @Test
    fun `clipboard yields when swipe choices are active even if startedTyping is false`() {
        val startedTyping = KeyboardChrome.startedTyping(composing = "", textBeforeCursor = "")
        assertFalse(startedTyping)
        assertFalse(KeyboardChrome.swipeWordArmed("hello", "", ""))
        assertTrue(
            KeyboardChrome.swipeChoicesActive(
                hasChoices = true,
                swipeArmed = false,
                startedTyping = false,
                composing = "",
            ),
        )
        assertNull(
            KeyboardChrome.clipboardForStrip(
                clip,
                startedTyping = false,
                swipeChoicesActive = true,
            ),
        )
        assertEquals(
            clip,
            KeyboardChrome.clipboardForStrip(
                clip,
                startedTyping = false,
                swipeChoicesActive = false,
            ),
        )
    }

    @Test
    fun `swipe choices stay inactive on an idle empty field`() {
        assertFalse(
            KeyboardChrome.swipeChoicesActive(
                hasChoices = false,
                swipeArmed = false,
                startedTyping = false,
                composing = "",
            ),
        )
        assertFalse(
            KeyboardChrome.swipeChoicesActive(
                hasChoices = true,
                swipeArmed = false,
                startedTyping = true,
                composing = "",
            ),
        )
        assertTrue(
            KeyboardChrome.swipeChoicesActive(
                hasChoices = true,
                swipeArmed = true,
                startedTyping = true,
                composing = "",
            ),
        )
        assertFalse(
            KeyboardChrome.swipeChoicesActive(
                hasChoices = true,
                swipeArmed = false,
                startedTyping = false,
                composing = "h",
            ),
        )
    }

    /** Clearing the field is the same condition that first offered the chip. */
    @Test
    fun `clearing the field offers the clip again`() {
        assertNull(KeyboardChrome.clipboardForStrip(clip, startedTyping = true))
        assertEquals(clip, KeyboardChrome.clipboardForStrip(clip, startedTyping = false))
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
    fun `swipe word stays armed while the cursor is on that word`() {
        assertTrue(KeyboardChrome.swipeWordArmed("hello", "hello ", ""))
        assertTrue(KeyboardChrome.swipeWordArmed("Hello", "hello ", ""))
        assertTrue(KeyboardChrome.swipeWordArmed("hello", "hello", ""))
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

    @Test
    fun `a cursor move inside a word drops the pending capital`() {
        assertEquals(
            ShiftState.OFF,
            KeyboardChrome.shiftAfterCursorSync(
                current = ShiftState.ONCE,
                atCursor = ShiftState.OFF,
            ),
        )
    }

    @Test
    fun `a cursor move at a sentence start arms one capital`() {
        assertEquals(
            ShiftState.ONCE,
            KeyboardChrome.shiftAfterCursorSync(
                current = ShiftState.OFF,
                atCursor = ShiftState.ONCE,
            ),
        )
    }

    @Test
    fun `caps lock survives a cursor move`() {
        assertEquals(
            ShiftState.LOCKED,
            KeyboardChrome.shiftAfterCursorSync(
                current = ShiftState.LOCKED,
                atCursor = ShiftState.OFF,
            ),
        )
    }
}
