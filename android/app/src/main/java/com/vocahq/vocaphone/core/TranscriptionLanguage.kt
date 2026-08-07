package com.vocahq.vocaphone.core

/**
 * Mirrors the gateway's accepted `language` values. Automatic is pinned
 * first as the default; the rest are alphabetical by [displayName].
 *
 * The Indian languages are the ones Whisper can be pinned to. Odia and Kashmiri
 * are deliberately absent: only Dolphin covers them, and Dolphin detects the
 * language itself, so choosing them here could never change what comes back.
 */
enum class TranscriptionLanguage(val wireValue: String) {
    AUTOMATIC("auto"),
    ARABIC("ar"),
    ASSAMESE("as"),
    BENGALI("bn"),
    DUTCH("nl"),
    ENGLISH("en"),
    FRENCH("fr"),
    GERMAN("de"),
    GUJARATI("gu"),
    HINDI("hi"),
    ITALIAN("it"),
    JAPANESE("ja"),
    KANNADA("kn"),
    KOREAN("ko"),
    MALAYALAM("ml"),
    MANDARIN_CHINESE("zh"),
    MARATHI("mr"),
    NEPALI("ne"),
    POLISH("pl"),
    PORTUGUESE("pt"),
    PUNJABI("pa"),
    RUSSIAN("ru"),
    SPANISH("es"),
    TAMIL("ta"),
    TELUGU("te"),
    UKRAINIAN("uk"),
    URDU("ur"),
    VIETNAMESE("vi");

    val displayName: String
        get() = when (this) {
            AUTOMATIC -> "Automatic"
            ARABIC -> "Arabic"
            ASSAMESE -> "Assamese"
            BENGALI -> "Bengali"
            DUTCH -> "Dutch"
            ENGLISH -> "English"
            FRENCH -> "French"
            GERMAN -> "German"
            GUJARATI -> "Gujarati"
            HINDI -> "Hindi"
            ITALIAN -> "Italian"
            JAPANESE -> "Japanese"
            KANNADA -> "Kannada"
            KOREAN -> "Korean"
            MALAYALAM -> "Malayalam"
            MANDARIN_CHINESE -> "Mandarin Chinese"
            MARATHI -> "Marathi"
            NEPALI -> "Nepali"
            POLISH -> "Polish"
            PORTUGUESE -> "Portuguese"
            PUNJABI -> "Punjabi"
            RUSSIAN -> "Russian"
            SPANISH -> "Spanish"
            TAMIL -> "Tamil"
            TELUGU -> "Telugu"
            UKRAINIAN -> "Ukrainian"
            URDU -> "Urdu"
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
