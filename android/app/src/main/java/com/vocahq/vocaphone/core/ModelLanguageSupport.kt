package com.vocahq.vocaphone.core

/**
 * Which languages the gateway's loaded model can actually be asked for.
 *
 * Offering a language the model cannot honour is how a dictation comes back in
 * the wrong alphabet: models that detect the language themselves ignore the
 * request entirely, and a model trained on other languages returns nothing.
 * Unavailable options are disabled rather than hidden, so the reason is visible
 * instead of the setting appearing to have gone missing.
 */
object ModelLanguageSupport {

    /**
     * [modelLanguages] empty means the gateway made no claim — an older build, no
     * model selected, or one the user imported. Nothing is disabled in that case:
     * a client that has not been told must never lock the user out.
     */
    fun isSelectable(
        language: TranscriptionLanguage,
        modelLanguages: Set<String>,
        detectsLanguageAutomatically: Boolean,
    ): Boolean {
        if (language == TranscriptionLanguage.AUTOMATIC) return true
        if (modelLanguages.isEmpty()) return !detectsLanguageAutomatically
        if (detectsLanguageAutomatically) return false
        return language.wireValue in modelLanguages
    }

    /**
     * The language to actually use. A stored choice goes stale when the gateway
     * switches models, and sending it anyway produces the exact failure this
     * exists to prevent, so it falls back to Automatic.
     */
    fun resolve(
        selected: TranscriptionLanguage,
        modelLanguages: Set<String>,
        detectsLanguageAutomatically: Boolean,
    ): TranscriptionLanguage =
        if (isSelectable(selected, modelLanguages, detectsLanguageAutomatically)) {
            selected
        } else {
            TranscriptionLanguage.AUTOMATIC
        }

    /** Why the picker is restricted, or null when it is not. */
    fun restriction(
        modelLanguages: Set<String>,
        detectsLanguageAutomatically: Boolean,
    ): String? = when {
        detectsLanguageAutomatically ->
            "Your gateway's model detects the language itself, so only Automatic applies. " +
                "It reads full sentences well but returns the wrong alphabet on short phrases."
        modelLanguages.isEmpty() -> null
        else -> "Your gateway's model covers ${modelLanguages.size} languages. " +
            "The rest need a different model."
    }
}
