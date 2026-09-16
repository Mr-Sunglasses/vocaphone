package com.vocahq.vocaphone.shared

/**
 * Platform-neutral language-selection rules used by both phone clients.
 *
 * The public boundary uses a newline-delimited set of language codes so Swift
 * can call the Kotlin/Native framework without carrying Kotlin collection
 * types through the app and keyboard targets. Newlines are not valid BCP-47
 * language-code characters, so the representation is unambiguous.
 */
object LanguagePolicy {
    fun transcriptLanguage(requested: String, reported: String, automaticLanguage: String): String =
        if (requested == automaticLanguage) reported else requested

    fun outputLanguage(
        requested: String,
        reported: String,
        translateTo: String,
        automaticLanguage: String,
    ): String = translateTo.ifEmpty { transcriptLanguage(requested, reported, automaticLanguage) }

    fun isSelectable(
        language: String,
        automaticLanguage: String,
        modelLanguageCodes: String,
    ): Boolean {
        val supported = languageCodes(modelLanguageCodes)
        return language == automaticLanguage || supported.isEmpty() || language in supported
    }

    fun resolve(
        selected: String,
        automaticLanguage: String,
        modelLanguageCodes: String,
    ): String = if (isSelectable(selected, automaticLanguage, modelLanguageCodes)) {
        selected
    } else {
        automaticLanguage
    }

    fun restriction(
        modelLanguageCodes: String,
        detectsLanguageAutomatically: Boolean,
        canTranslate: Boolean,
        onDevice: Boolean,
    ): String {
        val languages = languageCodes(modelLanguageCodes)
        val owner = if (onDevice) "The on-device model" else "Your gateway's model"
        val coverage = if (languages.isEmpty()) {
            null
        } else {
            val noun = if (languages.size == 1) "language" else "languages"
            "$owner covers ${languages.size} $noun. The rest need a different model."
        }
        val remedy = if (canTranslate) {
            "To change the language of the transcript, use Translate to."
        } else {
            "This model cannot translate, and picking a language you are not " +
                "speaking gives unreliable text rather than a translation."
        }
        val translation =
            "This is the language you are speaking, not the language you want back. $remedy"
        if (!detectsLanguageAutomatically) return listOfNotNull(coverage, translation).joinToString(" ")

        val subject = if (coverage == null) owner else "It"
        val detection = "$subject works out the spoken language itself, so picking one " +
            "here does not pin the decoder. Your choice sets the language the transcript " +
            "is punctuated and formatted in, which is what short phrases get wrong."
        return listOfNotNull(coverage, detection, translation).joinToString(" ")
    }

    private fun languageCodes(value: String): Set<String> =
        value.lineSequence().filter(String::isNotEmpty).toSet()
}
