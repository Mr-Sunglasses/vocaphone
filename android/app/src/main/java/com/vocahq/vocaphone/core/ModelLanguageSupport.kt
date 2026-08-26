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
     * The language token an engine is actually given.
     *
     * Roman Hinglish is not a language a decoder knows. The model that produces
     * it is a Hindi fine-tune, and the token it wants is `hi`; passing
     * `hinglish_roman` through to whisper.cpp gets the string rejected and the
     * decode falls back to detection. The distinction is kept everywhere else —
     * the transcript language stays `hinglish_roman`, which is what tells the
     * normalizer and the writing styles they are looking at Latin text.
     */
    fun decoderLanguage(requested: String): String =
        if (requested == TranscriptionLanguage.HINGLISH_ROMAN.wireValue) "hi" else requested

    /**
     * The language the finished transcript is actually written in.
     *
     * [translateTo] wins outright when set, and that is the whole point of the
     * overload: with translation on, the spoken language governs the decoder
     * while the target governs the text, and it is the text the writing styles
     * punctuate. Styling translated German by the Hindi that was spoken would
     * end a Latin sentence with a danda. Empty means no translation, which
     * leaves [transcriptLanguage] answering exactly as before.
     */
    fun outputLanguage(requested: String, reported: String, translateTo: String): String =
        translateTo.ifEmpty { transcriptLanguage(requested, reported) }

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
        // An output script inverts the default. "Nothing was claimed" is a good
        // reason not to lock a user out of Hindi, because almost everything
        // transcribes Hindi; it is a bad reason to offer Roman Hinglish, which
        // exactly one model in the catalog can produce and which every other
        // model would answer with Devanagari or an English translation. Silence
        // is a no here, and a gateway that has never heard of the value would
        // reject it as unsupported anyway.
        if (language.isOutputScript) return language.wireValue in modelLanguages
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
     * What the picker's choice does and does not do here.
     *
     * Never null any more: even an unrestricted model needs the sentence below
     * saying that this row is the language being spoken rather than the
     * language wanted back. The return type stays nullable so callers that
     * already handle absence keep compiling.
     *
     * [onDevice] only changes which model the sentence blames, but pointing a
     * user at their gateway when the constraint comes from the model on their
     * phone sends them to the wrong screen.
     *
     * [canTranslate] adds the sentence that says what this row is not. Whisper
     * takes its output language from a token forced into the decoder, so
     * picking a language nobody is speaking makes it emit that language
     * anyway — untrained behaviour that reads as translation and is the single
     * most common misreading of this screen. The sentence is unconditional
     * because the misreading survives being right about one model: someone who
     * learned the trick on Whisper carries it to Parakeet, where the pick is
     * discarded entirely.
     */
    fun restriction(
        modelLanguages: Set<String>,
        detectsLanguageAutomatically: Boolean,
        canTranslate: Boolean,
        onDevice: Boolean = false,
    ): String? {
        val owner = if (onDevice) "The on-device model" else "Your gateway's model"
        val coverage = if (modelLanguages.isEmpty()) {
            null
        } else {
            val noun = if (modelLanguages.size == 1) "language" else "languages"
            "$owner covers ${modelLanguages.size} $noun. The rest need a different model."
        }
        val remedy = if (canTranslate) {
            "To change the language of the transcript, use Translate to."
        } else {
            "This model cannot translate, and picking a language you are not " +
                "speaking gives unreliable text rather than a translation."
        }
        val translation =
            "This is the language you are speaking, not the language you want back. $remedy"
        if (!detectsLanguageAutomatically) {
            return listOfNotNull(coverage, translation).joinToString(" ")
        }
        // Said plainly rather than by disabling the rows: this model decides the
        // language from the audio, and the pick only tells the app how to
        // punctuate what comes back.
        val subject = if (coverage == null) owner else "It"
        val detection = "$subject works out the spoken language itself, so picking one " +
            "here does not pin the decoder. Your choice sets the language the transcript " +
            "is punctuated and formatted in, which is what short phrases get wrong."
        return listOfNotNull(coverage, detection, translation).joinToString(" ")
    }
}
