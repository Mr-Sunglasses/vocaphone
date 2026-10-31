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

    /**
     * Whether "Check grammar while typing" may read this field: prose only.
     * Not an address, a link, a search filter or a field that asked for no
     * suggestions — the app knows its field better than a grammar model does.
     */
    fun acceptsGrammarCheck(inputType: Int): Boolean {
        if (!acceptsDictation(inputType)) return false
        if (inputType and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS != 0) return false
        return inputType and InputType.TYPE_MASK_VARIATION !in NON_PROSE_TEXT_VARIATIONS
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

    private val NON_PROSE_TEXT_VARIATIONS = setOf(
        InputType.TYPE_TEXT_VARIATION_URI,
        InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
        InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS,
        InputType.TYPE_TEXT_VARIATION_FILTER,
        InputType.TYPE_TEXT_VARIATION_PERSON_NAME,
        InputType.TYPE_TEXT_VARIATION_POSTAL_ADDRESS,
        InputType.TYPE_TEXT_VARIATION_PHONETIC,
    )

    private val SENSITIVE_TEXT_VARIATIONS = setOf(
        InputType.TYPE_TEXT_VARIATION_PASSWORD,
        InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
        InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
    )
}
