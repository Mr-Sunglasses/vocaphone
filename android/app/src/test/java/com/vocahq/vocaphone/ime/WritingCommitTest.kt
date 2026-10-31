package com.vocahq.vocaphone.ime

import android.view.inputmethod.InputConnection
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WritingCommitTest {
    /** A plain-text editor that can refuse a selection or a commit. */
    private class Editor(var text: String, var cursor: Int) {
        var refuseSelection: Pair<Int, Int>? = null
        var refuseCommit = false
        val calls = mutableListOf<String>()
        private var selection = cursor to cursor
        val connection = Proxy.newProxyInstance(
            InputConnection::class.java.classLoader,
            arrayOf(InputConnection::class.java),
        ) { _, method, args ->
            calls += method.name
            when (method.name) {
                "setSelection" -> {
                    val range = args!![0] as Int to args[1] as Int
                    if (range == refuseSelection) {
                        false
                    } else {
                        selection = range
                        if (range.first == range.second) cursor = range.first
                        true
                    }
                }
                "commitText" -> {
                    if (refuseCommit) {
                        false
                    } else {
                        val inserted = args!![0].toString()
                        text = text.substring(0, selection.first) + inserted + text.substring(selection.second)
                        selection = (selection.first + inserted.length).let { it to it }
                        true
                    }
                }
                "beginBatchEdit", "endBatchEdit", "finishComposingText" -> true
                else -> error("Unexpected editor call: ${method.name}")
            }
        } as InputConnection
    }

    @Test
    fun `fixes land from the end back and the cursor follows`() {
        val editor = Editor("I definately recieve it. ", cursor = 25)
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
        val editor = Editor("I dont know ", cursor = 12)
        editor.refuseSelection = 2 to 6
        val commit = commitWritingFixes(editor.connection, listOf(WritingFix(2, 6, "don't")), 12, composingActive = true)
        assertEquals("I dont know ", editor.text)
        assertTrue(commit.applied.isEmpty())
        assertTrue("commitText" !in editor.calls)
        assertEquals("endBatchEdit", editor.calls.last())
    }

    @Test
    fun `a refused commit stops and still closes the batch`() {
        val editor = Editor("I dont know ", cursor = 12)
        editor.refuseCommit = true
        val commit = commitWritingFixes(editor.connection, listOf(WritingFix(2, 6, "don't")), 12, composingActive = false)
        assertTrue(commit.applied.isEmpty())
        assertEquals(12, editor.cursor)
        assertEquals("endBatchEdit", editor.calls.last())
    }

    @Test
    fun `a fix overlapping one already made is skipped`() {
        val editor = Editor("abc def ", cursor = 8)
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
