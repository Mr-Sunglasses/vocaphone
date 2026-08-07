package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TextInsertionTest {

    @Test
    fun `a field showing its placeholder is treated as empty`() {
        // Signal reports "Signal message" and Google reports "Ask Google" from
        // getText() while the field is empty; splicing after that put the app's
        // own placeholder into the user's message.
        assertEquals("", TextInsertion.fieldContents("Signal message", showingHintText = true))
        assertEquals("", TextInsertion.fieldContents("Ask Google", showingHintText = true))
        assertEquals("", TextInsertion.fieldContents(null, showingHintText = false))
        assertEquals("Real text", TextInsertion.fieldContents("Real text", showingHintText = false))
    }

    @Test
    fun `text matching the field's own hint is placeholder even without the flag`() {
        // WhatsApp's entry field reports its "Message" hint from getText()
        // with isShowingHintText false, which prefixed every dictation.
        assertEquals(
            "",
            TextInsertion.fieldContents("Message", showingHintText = false, hintText = "Message"),
        )
        // The two are reported through different paths, so case and spacing
        // may not agree even when they are the same placeholder.
        assertEquals(
            "",
            TextInsertion.fieldContents("Message", showingHintText = false, hintText = "message "),
        )
        assertEquals(
            "",
            TextInsertion.fieldContents("Type a message…", showingHintText = false, hintText = "Type a message…"),
        )
        assertEquals(
            "Message",
            TextInsertion.fieldContents("Message", showingHintText = false, hintText = "Type here"),
        )
        assertEquals(
            "Real text",
            TextInsertion.fieldContents("Real text", showingHintText = false, hintText = "Message"),
        )
    }

    @Test
    fun `dictating into an empty field produces only the transcript`() {
        val existing = TextInsertion.fieldContents("Signal message", showingHintText = true)
        val plan = TextInsertion.plan(existing, 0, 0, "Hey, we are using vocaphone app")!!

        assertEquals("Hey, we are using vocaphone app", plan.updatedText)
        assertEquals(0, plan.insertionStart)
    }

    @Test
    fun `inserts at the cursor and leaves the caret after the transcript`() {
        val plan = TextInsertion.plan("Hello world", 5, 5, "there")!!
        assertEquals("Hello there world", plan.updatedText)
        assertEquals(" there", plan.inserted)
        assertEquals(5, plan.insertionStart)
        assertEquals(11, plan.cursor)
    }

    @Test
    fun `replaces the selected range`() {
        val plan = TextInsertion.plan("Hello world", 6, 11, "everyone")!!
        assertEquals("Hello everyone", plan.updatedText)
        assertEquals(14, plan.cursor)
    }

    @Test
    fun `handles a reversed selection`() {
        val plan = TextInsertion.plan("Hello world", 11, 6, "everyone")!!
        assertEquals("Hello everyone", plan.updatedText)
    }

    @Test
    fun `adds no space next to punctuation or existing whitespace`() {
        assertEquals("Ready. Go", TextInsertion.plan("Ready. ", 7, 7, "Go")!!.updatedText)
        assertEquals("Wait, now", TextInsertion.plan("Wait", 4, 4, ", now")!!.updatedText)
    }

    @Test
    fun `separates the transcript from following text`() {
        val plan = TextInsertion.plan("ab", 1, 1, "middle")!!
        assertEquals("a middle b", plan.updatedText)
    }

    @Test
    fun `refuses a blank transcript or an out of range selection`() {
        assertNull(TextInsertion.plan("Hello", 0, 0, "   "))
        assertNull(TextInsertion.plan("Hello", 0, 99, "text"))
        assertNull(TextInsertion.plan("Hello", -1, 2, "text"))
    }

    @Test
    fun `undo removes the exact transcript that was written`() {
        val plan = TextInsertion.plan("Hello world", 5, 5, "there")!!
        assertEquals(
            "Hello world",
            TextInsertion.undo(plan.updatedText, plan.insertionStart, plan.inserted),
        )
    }

    @Test
    fun `undo refuses once the inserted text has been edited`() {
        val plan = TextInsertion.plan("Hello world", 5, 5, "there")!!
        val edited = plan.updatedText.replace("there", "THERE")
        assertNull(TextInsertion.undo(edited, plan.insertionStart, plan.inserted))
    }

    @Test
    fun `undo refuses when the field has shrunk past the insertion`() {
        val plan = TextInsertion.plan("Hello world", 5, 5, "there")!!
        assertNull(TextInsertion.undo("Hi", plan.insertionStart, plan.inserted))
        assertNull(TextInsertion.undo(plan.updatedText, plan.insertionStart, ""))
    }
}
