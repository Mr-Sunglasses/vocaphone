package com.vocahq.vocaphone.ime

import android.text.InputType
import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SwipeAllowedTest {
    private fun config(type: Int) = KeyboardEditorConfig.from(EditorInfo().apply { inputType = type }, sessionId = 1)

    @Test
    fun ordinaryTextAllowsSwipe() {
        assertTrue(config(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES).swipeAllowed)
        assertTrue(config(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_SHORT_MESSAGE).swipeAllowed)
    }

    @Test
    fun passwordsNeverSwipe() {
        assertFalse(config(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD).swipeAllowed)
        assertFalse(config(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD).swipeAllowed)
        assertFalse(config(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD).swipeAllowed)
    }

    @Test
    fun noSuggestionFieldsNeverSwipe() {
        assertFalse(config(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS).swipeAllowed)
    }

    @Test
    fun numberAndPhoneFieldsNeverSwipe() {
        assertFalse(config(InputType.TYPE_CLASS_NUMBER).swipeAllowed)
        assertFalse(config(InputType.TYPE_CLASS_PHONE).swipeAllowed)
        assertFalse(KeyboardEditorConfig.empty().swipeAllowed)
    }
}
