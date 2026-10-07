package com.vocahq.vocaphone.ime

import android.view.inputmethod.InputConnection
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DictationCommitTest {
    private class Editor(val before: String?, val after: String?, val accepts: Boolean = true) {
        var inserted: String? = null
        val reads = mutableListOf<String>()
        val calls = mutableListOf<String>()
        var selection: Pair<Int, Int>? = null
        val connection = Proxy.newProxyInstance(
            InputConnection::class.java.classLoader,
            arrayOf(InputConnection::class.java),
        ) { _, method, args ->
            calls += method.name
            when (method.name) {
                "getTextBeforeCursor", "getTextAfterCursor" -> {
                    assertEquals(1, args!![0])
                    assertEquals(0, args[1])
                    reads += method.name
                    if (method.name == "getTextBeforeCursor") before else after
                }
                "commitText" -> {
                    inserted = args!![0].toString()
                    assertEquals(1, args[1])
                    accepts
                }
                "setSelection" -> {
                    selection = args!![0] as Int to args[1] as Int
                    true
                }
                "beginBatchEdit", "endBatchEdit", "finishComposingText" -> true
                else -> error("Unexpected editor call: ${method.name}")
            }
        } as InputConnection
    }

    @Test
    fun `correction after a sentence receives a leading space`() {
        val editor = Editor(".", "")
        assertTrue(commitDictation(editor.connection, "Corrected sentence.", composingActive = false))
        assertEquals(" Corrected sentence.", editor.inserted)
        assertEquals(listOf("getTextBeforeCursor", "getTextAfterCursor"), editor.reads)
    }

    @Test
    fun `selected replacement separates both neighboring words`() {
        val editor = Editor("o", "w")
        assertTrue(commitDictation(editor.connection, "there", composingActive = false))
        assertEquals(" there ", editor.inserted)
    }

    @Test
    fun `existing whitespace and following punctuation need no extra spaces`() {
        val editor = Editor(" ", ",")
        assertTrue(commitDictation(editor.connection, "corrected", composingActive = false))
        assertEquals("corrected", editor.inserted)
    }

    @Test
    fun `editor without context still accepts dictation`() {
        val editor = Editor(null, null)
        assertTrue(commitDictation(editor.connection, "hello", composingActive = false))
        assertEquals("hello", editor.inserted)
    }

    @Test
    fun `refused commit and empty transcript do not report insertion`() {
        assertFalse(commitDictation(Editor("", "", accepts = false).connection, "hello", composingActive = false))
        val editor = Editor("a", "b")
        assertFalse(commitDictation(editor.connection, " ", composingActive = true))
        assertEquals(null, editor.inserted)
        assertTrue(editor.calls.isEmpty())
    }

    @Test
    fun `half-typed word is finished before the transcript so it is not replaced`() {
        // "hel" is still the composing region when the mic is tapped. commitText
        // alone would replace it; finishing first keeps it and the transcript
        // lands after it, separated by a space.
        val editor = Editor("l", "")
        assertTrue(commitDictation(editor.connection, "Hello world", composingActive = true))
        assertEquals(" Hello world", editor.inserted)
        assertEquals(
            listOf(
                "beginBatchEdit",
                "finishComposingText",
                "getTextBeforeCursor",
                "getTextAfterCursor",
                "commitText",
                "endBatchEdit",
            ),
            editor.calls,
        )
    }

    @Test
    fun `no composing region costs no finishComposingText round trip`() {
        val editor = Editor("", "")
        assertTrue(commitDictation(editor.connection, "hello", composingActive = false))
        assertFalse("finishComposingText" in editor.calls)
        assertEquals("beginBatchEdit", editor.calls.first())
        assertEquals("endBatchEdit", editor.calls.last())
    }

    @Test
    fun `batch edit is closed even when the editor refuses the commit`() {
        val editor = Editor("", "", accepts = false)
        assertFalse(commitDictation(editor.connection, "hello", composingActive = true))
        assertEquals("endBatchEdit", editor.calls.last())
    }

    @Test
    fun `highlighted text survives finishing the composing region`() {
        // "hel" is still composing when the user highlights "world" (5..10)
        // and dictates. Editors that collapse the highlight on
        // finishComposingText would otherwise get the transcript at the caret.
        val editor = Editor(" ", "")
        assertTrue(
            commitDictation(
                editor.connection,
                "there",
                composingActive = true,
                selectionStart = 5,
                selectionEnd = 10,
            ),
        )
        assertEquals(5 to 10, editor.selection)
        assertEquals(
            listOf(
                "beginBatchEdit",
                "finishComposingText",
                "setSelection",
                "getTextBeforeCursor",
                "getTextAfterCursor",
                "commitText",
                "endBatchEdit",
            ),
            editor.calls,
        )
    }

    @Test
    fun `selection is left alone when nothing was composing`() {
        val editor = Editor(" ", "")
        assertTrue(
            commitDictation(
                editor.connection,
                "there",
                composingActive = false,
                selectionStart = 5,
                selectionEnd = 10,
            ),
        )
        assertFalse("setSelection" in editor.calls)
    }

    @Test
    fun `collapsed cursor is not re-selected after finishing composition`() {
        val editor = Editor("l", "")
        assertTrue(
            commitDictation(
                editor.connection,
                "Hello",
                composingActive = true,
                selectionStart = 3,
                selectionEnd = 3,
            ),
        )
        assertFalse("setSelection" in editor.calls)
    }
}
