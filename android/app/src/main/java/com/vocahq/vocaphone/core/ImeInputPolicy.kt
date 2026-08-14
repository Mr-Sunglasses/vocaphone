package com.vocahq.vocaphone.core

import android.text.InputType

/**
 * The editor fields into which the VocaPhone keyboard may offer dictation.
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

        return !isSensitive(inputType)
    }

    /** Used only to explain why the mic is hidden. Suggestions also stay off here. */
    fun isSensitive(inputType: Int): Boolean {
        val inputClass = inputType and InputType.TYPE_MASK_CLASS
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return when (inputClass) {
            InputType.TYPE_CLASS_TEXT -> variation in SENSITIVE_TEXT_VARIATIONS
            InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }

    private val SENSITIVE_TEXT_VARIATIONS = setOf(
        InputType.TYPE_TEXT_VARIATION_PASSWORD,
        InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
        InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
    )
}
