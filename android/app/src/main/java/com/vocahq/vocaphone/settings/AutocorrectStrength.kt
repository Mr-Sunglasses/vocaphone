package com.vocahq.vocaphone.settings

/**
 * How sure the keyboard has to be before space or punctuation replaces a typed
 * word. Only matters while "Corrections" is on; see
 * [com.vocahq.vocaphone.ime.Autocorrect] for what each level allows.
 */
enum class AutocorrectStrength(val storedValue: String) {
    /** One-letter slips only, and only with a clear winner. */
    MILD("mild"),
    NORMAL("normal"),
    /** Two-letter slips, and a smaller lead over the next reading. */
    AGGRESSIVE("aggressive"),
    ;

    val displayName: String
        get() = when (this) {
            MILD -> "Mild"
            NORMAL -> "Normal"
            AGGRESSIVE -> "Aggressive"
        }

    companion object {
        val DEFAULT = NORMAL

        fun fromStored(value: String?): AutocorrectStrength =
            entries.firstOrNull { it.storedValue == value } ?: DEFAULT
    }
}
