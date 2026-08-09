package com.vocahq.vocaphone.core

import android.text.InputType

/**
 * The editor fields into which the experimental keyboard may offer dictation.
 *
 * The IME can see an EditorInfo without reading the field contents. Keeping this
 * gate limited to ordinary text fields prevents the keyboard from presenting a
 * microphone action in passwords, PINs, phone numbers or date fields.
 */
object ImeInputPolicy {

    fun acceptsDictation(inputType: Int): Boolean {
        if (inputType and InputType.TYPE_MASK_CLASS != InputType.TYPE_CLASS_TEXT) {
            return false
        }

        return inputType and InputType.TYPE_MASK_VARIATION !in SENSITIVE_VARIATIONS
    }

    private val SENSITIVE_VARIATIONS = setOf(
        InputType.TYPE_TEXT_VARIATION_PASSWORD,
        InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
        InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
    )
}
