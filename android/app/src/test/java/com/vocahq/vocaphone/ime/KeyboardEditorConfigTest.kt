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
}
