package com.vocahq.vocaphone.core

/**
 * Every language a model in the catalog can be asked for. Automatic is pinned
 * first as the default; the rest are alphabetical by [displayName].
 *
 * The list is drawn from what the shipped models actually cover, not from
 * Whisper's full hundred: Parakeet TDT v3's 25 European languages, SenseVoice's
 * East Asian five, Dolphin's Indic and South East Asian range, and the widely
 * spoken languages Whisper handles well at phone-sized quantizations. A code
 * here is meaningless unless some model can honour it, and the picker greys out
 * the ones the active model does not cover.
 *
 * Odia and Kashmiri are deliberately absent: only Dolphin covers them, and no
 * Whisper build can be pinned to either, so a row for them could never be
 * honoured by anything the user could switch to.
 */
enum class TranscriptionLanguage(val wireValue: String) {
    AUTOMATIC("auto"),
    ARABIC("ar"),
    ASSAMESE("as"),
    BENGALI("bn"),
    BULGARIAN("bg"),
    CANTONESE("yue"),
    CATALAN("ca"),
    CROATIAN("hr"),
    CZECH("cs"),
    DANISH("da"),
    DUTCH("nl"),
    ENGLISH("en"),
    ESTONIAN("et"),
    FILIPINO("tl"),
    FINNISH("fi"),
    FRENCH("fr"),
    GERMAN("de"),
    GREEK("el"),
    GUJARATI("gu"),
    HEBREW("he"),
    HINDI("hi"),
    HUNGARIAN("hu"),
    INDONESIAN("id"),
    ITALIAN("it"),
    JAPANESE("ja"),
    KANNADA("kn"),
    KOREAN("ko"),
    LATVIAN("lv"),
    LITHUANIAN("lt"),
    MALAY("ms"),
    MALAYALAM("ml"),
    MALTESE("mt"),
    MANDARIN_CHINESE("zh"),
    MARATHI("mr"),
    NEPALI("ne"),
    NORWEGIAN("no"),
    PERSIAN("fa"),
    POLISH("pl"),
    PORTUGUESE("pt"),
    PUNJABI("pa"),
    ROMANIAN("ro"),
    RUSSIAN("ru"),
    SERBIAN("sr"),
    SLOVAK("sk"),
    SLOVENIAN("sl"),
    SPANISH("es"),
    SWAHILI("sw"),
    SWEDISH("sv"),
    TAMIL("ta"),
    TELUGU("te"),
    THAI("th"),
    TURKISH("tr"),
    UKRAINIAN("uk"),
    URDU("ur"),
    VIETNAMESE("vi");

    val displayName: String
        get() = when (this) {
            AUTOMATIC -> "Automatic"
            ARABIC -> "Arabic"
            ASSAMESE -> "Assamese"
            BENGALI -> "Bengali"
            BULGARIAN -> "Bulgarian"
            CANTONESE -> "Cantonese"
            CATALAN -> "Catalan"
            CROATIAN -> "Croatian"
            CZECH -> "Czech"
            DANISH -> "Danish"
            DUTCH -> "Dutch"
            ENGLISH -> "English"
            ESTONIAN -> "Estonian"
            FILIPINO -> "Filipino"
            FINNISH -> "Finnish"
            FRENCH -> "French"
            GERMAN -> "German"
            GREEK -> "Greek"
            GUJARATI -> "Gujarati"
            HEBREW -> "Hebrew"
            HINDI -> "Hindi"
            HUNGARIAN -> "Hungarian"
            INDONESIAN -> "Indonesian"
            ITALIAN -> "Italian"
            JAPANESE -> "Japanese"
            KANNADA -> "Kannada"
            KOREAN -> "Korean"
            LATVIAN -> "Latvian"
            LITHUANIAN -> "Lithuanian"
            MALAY -> "Malay"
            MALAYALAM -> "Malayalam"
            MALTESE -> "Maltese"
            MANDARIN_CHINESE -> "Mandarin Chinese"
            MARATHI -> "Marathi"
            NEPALI -> "Nepali"
            NORWEGIAN -> "Norwegian"
            PERSIAN -> "Persian"
            POLISH -> "Polish"
            PORTUGUESE -> "Portuguese"
            PUNJABI -> "Punjabi"
            ROMANIAN -> "Romanian"
            RUSSIAN -> "Russian"
            SERBIAN -> "Serbian"
            SLOVAK -> "Slovak"
            SLOVENIAN -> "Slovenian"
            SPANISH -> "Spanish"
            SWAHILI -> "Swahili"
            SWEDISH -> "Swedish"
            TAMIL -> "Tamil"
            TELUGU -> "Telugu"
            THAI -> "Thai"
            TURKISH -> "Turkish"
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
