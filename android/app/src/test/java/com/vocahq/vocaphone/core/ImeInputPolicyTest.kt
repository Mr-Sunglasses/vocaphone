package com.vocahq.vocaphone.core

import android.text.InputType
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
}
