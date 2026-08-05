package io.github.mrsunglasses.localflow.core

/**
 * Mirrors the gateway's accepted `language` values and the iOS client's
 * `TranscriptionLanguage`, in the same order.
 */
enum class TranscriptionLanguage(val wireValue: String) {
    AUTOMATIC("auto"),
    ENGLISH("en"),
    SPANISH("es"),
    ARABIC("ar"),
    JAPANESE("ja"),
    KOREAN("ko"),
    MANDARIN_CHINESE("zh"),
    UKRAINIAN("uk"),
    RUSSIAN("ru"),
    VIETNAMESE("vi");

    val displayName: String
        get() = when (this) {
            AUTOMATIC -> "Automatic"
            ENGLISH -> "English"
            SPANISH -> "Spanish"
            ARABIC -> "Arabic"
            JAPANESE -> "Japanese"
            KOREAN -> "Korean"
            MANDARIN_CHINESE -> "Mandarin Chinese"
            UKRAINIAN -> "Ukrainian"
            RUSSIAN -> "Russian"
            VIETNAMESE -> "Vietnamese"
        }

    val shortLabel: String
        get() = if (this == AUTOMATIC) "Auto" else wireValue.uppercase()

    val detail: String
        get() = when (this) {
            AUTOMATIC -> "Uses the language of the model selected on your gateway."
            else -> "Requires a matching multilingual or $displayName model on your gateway."
        }

    companion object {
        val DEFAULT = AUTOMATIC

        fun fromWire(value: String?): TranscriptionLanguage =
            entries.firstOrNull { it.wireValue == value } ?: DEFAULT
    }
}
