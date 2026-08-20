package com.vocahq.vocaphone.ime

import android.text.InputType
import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardEditorConfigTest {

    @Test
    fun `email fields expose at sign and allow dictation`() {
        val config = KeyboardEditorConfig.from(
            EditorInfo().apply {
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
            },
            sessionId = 4,
        )

        assertEquals("@", config.leadingPunctuation)
        assertTrue(config.dictationAllowed)
        assertFalse(config.sensitive)
    }

    @Test
    fun `password fields remain typing only`() {
        val config = KeyboardEditorConfig.from(
            EditorInfo().apply {
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            },
            sessionId = 2,
        )

        assertFalse(config.dictationAllowed)
        assertTrue(config.sensitive)
        assertEquals(KeyboardLayer.LETTERS, config.initialLayer)
    }

    @Test
    fun `number fields start on number layer`() {
        val config = KeyboardEditorConfig.from(
            EditorInfo().apply { inputType = InputType.TYPE_CLASS_NUMBER },
            sessionId = 8,
        )

        assertEquals(KeyboardLayer.NUMBERS, config.initialLayer)
        assertFalse(config.dictationAllowed)
    }

    @Test
    fun `search fields use the editor search action`() {
        val config = KeyboardEditorConfig.from(
            EditorInfo().apply {
                inputType = InputType.TYPE_CLASS_TEXT
                imeOptions = EditorInfo.IME_ACTION_SEARCH
            },
            sessionId = 3,
        )

        assertEquals(ReturnKeyKind.SEARCH, config.returnKey)
        assertEquals(EditorInfo.IME_ACTION_SEARCH, config.editorActionId)
    }

    @Test
    fun `no-enter-action flag keeps a newline key`() {
        val config = KeyboardEditorConfig.from(
            EditorInfo().apply {
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
                imeOptions = EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_ENTER_ACTION
            },
            sessionId = 9,
        )

        assertEquals(ReturnKeyKind.ENTER, config.returnKey)
        assertNull(config.editorActionId)
    }

    @Test
    fun `sentence-cap flag alone does not force shift mid sentence`() {
        val config = KeyboardEditorConfig.from(
            EditorInfo().apply {
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                initialCapsMode = 0
            },
            sessionId = 1,
        )
        assertEquals(ShiftState.OFF, config.initialShift)
    }

    @Test
    fun `cursor caps mode turns shift on once`() {
        val config = KeyboardEditorConfig.from(
            EditorInfo().apply {
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                initialCapsMode = InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            },
            sessionId = 1,
        )
        assertEquals(ShiftState.ONCE, config.initialShift)
    }

    @Test
    fun `all-caps fields lock shift`() {
        assertEquals(
            ShiftState.LOCKED,
            KeyboardEditorConfig.shiftFromCapsMode(InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS),
        )
        assertEquals(ShiftState.OFF, KeyboardEditorConfig.shiftFromCapsMode(0))
    }

    @Test
    fun `restarting the same field keeps the session`() {
        assertTrue(
            EditorRestart.keepsSession(
                previous = EditorIdentity.of(messageField()),
                next = EditorIdentity.of(messageField()),
            ),
        )
    }

    @Test
    fun `the same field is kept even when the framework forgets to say restarting`() {
        // The whole point of comparing the editor rather than branching on the
        // `restarting` flag: an app or an OEM framework that reports a restart
        // as a fresh connection must not cost the user their layer.
        val identity = EditorIdentity.of(messageField())

        assertEquals(identity, EditorIdentity.of(messageField()))
        assertTrue(EditorRestart.keepsSession(identity, EditorIdentity.of(messageField())))
    }

    @Test
    fun `focusing a second field starts a new session`() {
        val second = messageField().apply { fieldId = 202 }

        assertFalse(
            EditorRestart.keepsSession(
                previous = EditorIdentity.of(messageField()),
                next = EditorIdentity.of(second),
            ),
        )
    }

    @Test
    fun `a field that changes input type under a restart starts over`() {
        val password = messageField().apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }

        assertFalse(
            EditorRestart.keepsSession(
                previous = EditorIdentity.of(messageField()),
                next = EditorIdentity.of(password),
            ),
        )
    }

    @Test
    fun `a first connection is never a restart`() {
        // onFinishInput clears the stored identity, so this is also the path a
        // genuine focus change between two identical-looking fields takes.
        assertFalse(
            EditorRestart.keepsSession(
                previous = null,
                next = EditorIdentity.of(messageField()),
            ),
        )
    }

    private fun messageField() = EditorInfo().apply {
        fieldId = 101
        packageName = "com.example.chat"
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        imeOptions = EditorInfo.IME_ACTION_SEND
    }
}
