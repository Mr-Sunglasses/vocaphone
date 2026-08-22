package com.vocahq.vocaphone.core

/**
 * Which languages the loaded model can actually be asked for.
 *
 * Coverage is the whole test. A model trained on other languages returns
 * nothing, so those stay disabled rather than hidden, and the reason stays
 * visible instead of the setting appearing to have gone missing.
 *
 * Whether the model detects the language itself is a separate question from
 * whether it covers one. It used to collapse the picker to Automatic, which
 * left a 25-language model looking like it spoke none of them, and left the
 * writing-style pass with no language to punctuate by: those decoders report
 * nothing back, so "auto" resolved to the empty string and Cyrillic came back
 * finished with Latin full stops. The languages such a model covers are offered,
 * and [restriction] says exactly what picking one does and does not do.
 */
object ModelLanguageSupport {

    /**
     * An explicit selection is the output contract. Engine-reported language is
     * useful only for Automatic; letting it override a selected language makes
     * the writing-style pass use punctuation from a different script.
     */
    fun transcriptLanguage(requested: String, reported: String): String =
        if (requested == TranscriptionLanguage.AUTOMATIC.wireValue) reported else requested

    /**
     * [modelLanguages] empty means nothing was claimed — an older gateway build,
     * no model selected, or one the user imported. Nothing is disabled in that
     * case: a client that has not been told must never lock the user out.
     *
     * Whether the model detects the language itself is deliberately not an
     * argument here. It changes what the choice means, not which choices exist,
     * and [restriction] is where that difference is spelled out.
     */
    fun isSelectable(
        language: TranscriptionLanguage,
        modelLanguages: Set<String>,
    ): Boolean {
        if (language == TranscriptionLanguage.AUTOMATIC) return true
        if (modelLanguages.isEmpty()) return true
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
    ): TranscriptionLanguage =
        if (isSelectable(selected, modelLanguages)) {
            selected
        } else {
            TranscriptionLanguage.AUTOMATIC
        }

    /**
     * Why the picker is restricted, or null when it is not.
     *
     * [onDevice] only changes which model the sentence blames, but pointing a
     * user at their gateway when the constraint comes from the model on their
     * phone sends them to the wrong screen.
     */
    fun restriction(
        modelLanguages: Set<String>,
        detectsLanguageAutomatically: Boolean,
        onDevice: Boolean = false,
    ): String? {
        val owner = if (onDevice) "The on-device model" else "Your gateway's model"
        val coverage = if (modelLanguages.isEmpty()) {
            null
        } else {
            val noun = if (modelLanguages.size == 1) "language" else "languages"
            "$owner covers ${modelLanguages.size} $noun. The rest need a different model."
        }
        if (!detectsLanguageAutomatically) return coverage
        // Said plainly rather than by disabling the rows: this model decides the
        // language from the audio, and the pick only tells the app how to
        // punctuate what comes back.
        val subject = if (coverage == null) owner else "It"
        val detection = "$subject works out the spoken language itself, so picking one " +
            "here does not pin the decoder. Your choice sets the language the transcript " +
            "is punctuated and formatted in, which is what short phrases get wrong."
        return listOfNotNull(coverage, detection).joinToString(" ")
    }
}
