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
        val connection = Proxy.newProxyInstance(
            InputConnection::class.java.classLoader,
            arrayOf(InputConnection::class.java),
        ) { _, method, args ->
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
                else -> error("Unexpected editor call: ${method.name}")
            }
        } as InputConnection
    }

    @Test
    fun `correction after a sentence receives a leading space`() {
        val editor = Editor(".", "")
        assertTrue(commitDictation(editor.connection, "Corrected sentence."))
        assertEquals(" Corrected sentence.", editor.inserted)
        assertEquals(listOf("getTextBeforeCursor", "getTextAfterCursor"), editor.reads)
    }

    @Test
    fun `selected replacement separates both neighboring words`() {
        val editor = Editor("o", "w")
        assertTrue(commitDictation(editor.connection, "there"))
        assertEquals(" there ", editor.inserted)
    }

    @Test
    fun `existing whitespace and following punctuation need no extra spaces`() {
        val editor = Editor(" ", ",")
        assertTrue(commitDictation(editor.connection, "corrected"))
        assertEquals("corrected", editor.inserted)
    }

    @Test
    fun `editor without context still accepts dictation`() {
        val editor = Editor(null, null)
        assertTrue(commitDictation(editor.connection, "hello"))
        assertEquals("hello", editor.inserted)
    }

    @Test
    fun `refused commit and empty transcript do not report insertion`() {
        assertFalse(commitDictation(Editor("", "", accepts = false).connection, "hello"))
        val editor = Editor("a", "b")
        assertFalse(commitDictation(editor.connection, " "))
        assertEquals(null, editor.inserted)
        assertTrue(editor.reads.isEmpty())
    }
}
