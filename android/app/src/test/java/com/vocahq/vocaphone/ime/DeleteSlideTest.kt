package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Test

class DeleteSlideTest {
    @Test
    fun `option-delete takes the spaces and punctuation with the word before them`() {
        assertEquals(7, SuggestionEngine.wordWithSeparatorsBefore("hello world. "))
        assertEquals(5, SuggestionEngine.wordWithSeparatorsBefore("hello world"))
        assertEquals(7, SuggestionEngine.wordWithSeparatorsBefore("hello, "))
        assertEquals(3, SuggestionEngine.wordWithSeparatorsBefore("   "))
        assertEquals(0, SuggestionEngine.wordWithSeparatorsBefore(""))
    }

    @Test
    fun `each step left deletes one more word`() {
        val slide = DeleteSlide("one two, three ")
        assertEquals(listOf(KeyboardCommand.DeleteSurrounding(6, 0)), slide.moveTo(1))
        assertEquals("one two, ", slide.before)
        assertEquals(listOf(KeyboardCommand.DeleteSurrounding(5, 0)), slide.moveTo(2))
        assertEquals("one ", slide.before)
        // The same step again changes nothing.
        assertEquals(emptyList<KeyboardCommand>(), slide.moveTo(2))
    }

    @Test
    fun `sliding back types the words back, newest first`() {
        val slide = DeleteSlide("one two three")
        slide.moveTo(3)
        assertEquals("", slide.before)
        assertEquals(
            listOf(KeyboardCommand.CommitText("one "), KeyboardCommand.CommitText("two ")),
            slide.moveTo(1),
        )
        assertEquals("one two ", slide.before)
        assertEquals(listOf(KeyboardCommand.CommitText("three")), slide.moveTo(0))
        assertEquals("one two three", slide.before)
    }

    @Test
    fun `an empty field stops the slide`() {
        val slide = DeleteSlide("hi")
        assertEquals(1, slide.moveTo(5).size)
        assertEquals(1, slide.steps)
    }

    @Test
    fun `steps are whole key widths left of the press`() {
        assertEquals(0, DeleteSlide.stepsFor(travelPx = 39f, keyWidthPx = 40f))
        assertEquals(1, DeleteSlide.stepsFor(travelPx = 40f, keyWidthPx = 40f))
        assertEquals(2, DeleteSlide.stepsFor(travelPx = 95f, keyWidthPx = 40f))
        assertEquals(0, DeleteSlide.stepsFor(travelPx = -80f, keyWidthPx = 40f))
    }
}
