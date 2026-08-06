package io.github.mrsunglasses.localflow.core

/**
 * Mirrors the gateway's accepted `language` values. Automatic is pinned
 * first as the default; the rest are alphabetical by [displayName].
 */
enum class TranscriptionLanguage(val wireValue: String) {
    ARABIC("ar"),
    AUTOMATIC("auto"),
    ENGLISH("en"),
    FRENCH("fr"),
    GERMAN("de"),
    JAPANESE("ja"),
    KOREAN("ko"),
    MANDARIN_CHINESE("zh"),
    RUSSIAN("ru"),
    SPANISH("es"),
    UKRAINIAN("uk"),
    VIETNAMESE("vi");

    val displayName: String
        get() = when (this) {
            AUTOMATIC -> "Automatic"
            ARABIC -> "Arabic"
            ENGLISH -> "English"
            FRENCH -> "French"
            JAPANESE -> "Japanese"
            KOREAN -> "Korean"
            MANDARIN_CHINESE -> "Mandarin Chinese"
            RUSSIAN -> "Russian"
            SPANISH -> "Spanish"
            UKRAINIAN -> "Ukrainian"
            VIETNAMESE -> "Vietnamese"
            GERMAN -> "German"
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
