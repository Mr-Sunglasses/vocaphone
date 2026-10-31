package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WritingCommitTest {
    @Test
    fun `fixes land from the end back and the cursor follows`() {
        val editor = FakeWritingEditor("I definately recieve it. ", cursor = 25)
        val commit = commitWritingFixes(
            editor.connection,
            listOf(WritingFix(2, 12, "definitely"), WritingFix(13, 20, "receive")),
            cursor = 25,
            composingActive = false,
        )
        assertEquals("I definitely receive it. ", editor.text)
        assertEquals(listOf(13, 2), commit.applied.map { it.start })
        assertEquals(25, commit.cursor)
        assertEquals(25, editor.cursor)
    }

    @Test
    fun `a refused selection writes nothing at the cursor`() {
        val editor = FakeWritingEditor("I dont know ", cursor = 12)
        editor.refuseSelection = 2 to 6
        val commit = commitWritingFixes(editor.connection, listOf(WritingFix(2, 6, "don't")), 12, composingActive = true)
        assertEquals("I dont know ", editor.text)
        assertTrue(commit.applied.isEmpty())
        assertTrue("commitText" !in editor.calls)
        assertEquals("endBatchEdit", editor.calls.last())
    }

    @Test
    fun `a refused commit stops and still closes the batch`() {
        val editor = FakeWritingEditor("I dont know ", cursor = 12)
        editor.refuseCommit = true
        val commit = commitWritingFixes(editor.connection, listOf(WritingFix(2, 6, "don't")), 12, composingActive = false)
        assertTrue(commit.applied.isEmpty())
        assertEquals(12, editor.cursor)
        assertEquals("endBatchEdit", editor.calls.last())
    }

    @Test
    fun `a fix overlapping one already made is skipped`() {
        val editor = FakeWritingEditor("abc def ", cursor = 8)
        val commit = commitWritingFixes(
            editor.connection,
            listOf(WritingFix(0, 7, "x"), WritingFix(4, 7, "DEF")),
            cursor = 8,
            composingActive = false,
        )
        assertEquals("abc DEF ", editor.text)
        assertEquals(listOf(4), commit.applied.map { it.start })
    }
}
