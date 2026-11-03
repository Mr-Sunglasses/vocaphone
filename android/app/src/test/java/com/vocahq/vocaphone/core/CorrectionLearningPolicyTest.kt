package com.vocahq.vocaphone.core

import android.text.InputType
import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which fields the keyboard may read a dictation back from, to learn the user's fixes. */
class CorrectionLearningPolicyTest {
    private val text = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES

    @Test
    fun `an ordinary text field may be learned from`() {
        assertTrue(CorrectionLearningPolicy.allowsLearning(text, EditorInfo.IME_ACTION_SEND, "Message", "compose"))
    }

    @Test
    fun `secrets are never read`() {
        val password = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        assertFalse(CorrectionLearningPolicy.allowsLearning(password, 0, null, null))
        assertFalse(CorrectionLearningPolicy.allowsLearning(InputType.TYPE_CLASS_NUMBER, 0, null, null))
        assertFalse(CorrectionLearningPolicy.allowsLearning(text, 0, "Enter OTP", null))
        assertFalse(CorrectionLearningPolicy.allowsLearning(text, 0, null, "card_number"))
    }

    @Test
    fun `a field that asks keyboards not to learn is left alone`() {
        val incognito = EditorInfo.IME_ACTION_GO or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        assertFalse(CorrectionLearningPolicy.allowsLearning(text, incognito, "Search", null))
    }
}
