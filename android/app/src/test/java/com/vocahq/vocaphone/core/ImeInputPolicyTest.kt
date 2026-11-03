package com.vocahq.vocaphone.core

import android.text.InputType
import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImeInputPolicyTest {

    @Test
    fun `ordinary text fields offer dictation`() {
        assertTrue(ImeInputPolicy.acceptsDictation(InputType.TYPE_CLASS_TEXT))
        assertTrue(
            ImeInputPolicy.acceptsDictation(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            ),
        )
    }

    @Test
    fun `password fields never offer dictation`() {
        assertFalse(
            ImeInputPolicy.acceptsDictation(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            ),
        )
        assertFalse(
            ImeInputPolicy.acceptsDictation(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            ),
        )
        assertFalse(
            ImeInputPolicy.acceptsDictation(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            ),
        )
    }

    @Test
    fun `non-text fields do not offer dictation`() {
        assertFalse(ImeInputPolicy.acceptsDictation(InputType.TYPE_CLASS_NUMBER))
        assertFalse(ImeInputPolicy.acceptsDictation(InputType.TYPE_CLASS_PHONE))
        assertFalse(ImeInputPolicy.acceptsDictation(InputType.TYPE_CLASS_DATETIME))
    }

    @Test
    fun `grammar is checked in prose fields only`() {
        val text = InputType.TYPE_CLASS_TEXT
        assertTrue(ImeInputPolicy.acceptsGrammarCheck(text))
        assertTrue(ImeInputPolicy.acceptsGrammarCheck(text or InputType.TYPE_TEXT_VARIATION_SHORT_MESSAGE))
        assertTrue(ImeInputPolicy.acceptsGrammarCheck(text or InputType.TYPE_TEXT_VARIATION_EMAIL_SUBJECT))
        assertTrue(ImeInputPolicy.acceptsGrammarCheck(text or InputType.TYPE_TEXT_FLAG_MULTI_LINE))
        assertFalse(ImeInputPolicy.acceptsGrammarCheck(text or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS))
        assertFalse(ImeInputPolicy.acceptsGrammarCheck(text or InputType.TYPE_TEXT_VARIATION_URI))
        assertFalse(ImeInputPolicy.acceptsGrammarCheck(text or InputType.TYPE_TEXT_VARIATION_FILTER))
        assertFalse(ImeInputPolicy.acceptsGrammarCheck(text or InputType.TYPE_TEXT_VARIATION_PERSON_NAME))
        assertFalse(ImeInputPolicy.acceptsGrammarCheck(text or InputType.TYPE_TEXT_VARIATION_PASSWORD))
        assertFalse(ImeInputPolicy.acceptsGrammarCheck(text or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS))
        assertFalse(ImeInputPolicy.acceptsGrammarCheck(InputType.TYPE_CLASS_NUMBER))
    }

    @Test
    fun `number passwords are identified as sensitive`() {
        assertTrue(
            ImeInputPolicy.isSensitive(
                InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD,
            ),
        )
    }

    @Test
    fun `nearby text is read only where dictation is offered and learning is allowed`() {
        val text = InputType.TYPE_CLASS_TEXT
        assertTrue(ImeInputPolicy.allowsContextRead(text, EditorInfo.IME_ACTION_SEND, "Message", null))
        assertFalse(
            ImeInputPolicy.allowsContextRead(
                text or InputType.TYPE_TEXT_VARIATION_PASSWORD, EditorInfo.IME_ACTION_DONE, null, null,
            ),
        )
        assertFalse(ImeInputPolicy.allowsContextRead(InputType.TYPE_CLASS_NUMBER, 0, null, null))
        // Incognito tabs and private messaging ask keyboards not to learn.
        assertFalse(
            ImeInputPolicy.allowsContextRead(
                text, EditorInfo.IME_ACTION_GO or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING, null, null,
            ),
        )
        assertFalse(ImeInputPolicy.allowsContextRead(text, 0, "Enter your OTP", null))
        assertFalse(ImeInputPolicy.allowsContextRead(text, 0, null, "recovery_phrase"))
    }
}
