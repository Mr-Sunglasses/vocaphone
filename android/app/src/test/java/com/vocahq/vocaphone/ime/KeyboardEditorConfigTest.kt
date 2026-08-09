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
}
