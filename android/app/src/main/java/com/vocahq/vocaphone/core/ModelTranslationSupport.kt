package com.vocahq.vocaphone.core

/**
 * Which languages a model can *translate into*, as opposed to transcribe.
 *
 * This is a different question from [ModelLanguageSupport], and conflating the
 * two is what this file exists to stop. Transcription coverage asks what the
 * decoder can understand; translation coverage asks what it was trained to
 * emit for speech in some other language. Almost nothing on a phone can do the
 * second, and the two models that can do it in opposite directions:
 *
 *  - **Canary** is a speech-translation model proper. Its config carries a
 *    source and a target language, and it was trained on the pairs between
 *    English, German, Spanish and French.
 *  - **Whisper** translates *into English only*. That is the `<|translate|>`
 *    task, roughly a fifth of its training data, and no other target was ever
 *    trained. Asking it for any other target is not a smaller version of the
 *    same feature; it is nothing at all.
 *
 * Every other family — the transducers, the CTC models, Moonshine, Paraformer —
 * transcribes what it heard and has no mechanism to do anything else.
 *
 * A word on the failure this replaces. Whisper picks its output language from a
 * token forced into the decoder before the first word, so selecting a language
 * the speaker is not speaking makes it emit that language anyway: it satisfies
 * the forced token the only way it can, by rendering the meaning it heard. That
 * looks like translation and is occasionally even good, but it is untrained
 * behaviour that transliterates, reverts mid-sentence and drops clauses, and no
 * transducer can imitate it. Translation is a request the model either supports
 * or does not, and [targets] is the only thing allowed to answer.
 */
object ModelTranslationSupport {

    /**
     * [AUTOMATIC][TranscriptionLanguage.AUTOMATIC] is how "do not translate" is
     * stored. The picker needs a row for it, the setting needs a default, and
     * reusing the language enum keeps one wire vocabulary instead of two.
     */
    val OFF: TranscriptionLanguage = TranscriptionLanguage.AUTOMATIC

    /**
     * What the [OFF] row is called in the picker.
     *
     * Not "Automatic", which is the shared enum's own label and describes
     * language detection — the opposite of what choosing it here means. The
     * settings row says "Off" instead, because a row reading "Don't translate"
     * next to the word "Translate to" reads as a double negative.
     */
    const val OFF_LABEL = "Don't translate"

    /** Whether this model can translate at all, and so whether to offer the row. */
    fun isSupported(targets: Set<String>): Boolean = targets.isNotEmpty()

    fun isSelectable(language: TranscriptionLanguage, targets: Set<String>): Boolean =
        language == OFF || language.wireValue in targets

    /**
     * The target to actually use. A stored choice goes stale the moment the
     * user switches models — from Canary to Parakeet, or to a gateway — and
     * silently translating nothing is far better than a request the engine
     * cannot honour.
     */
    fun resolve(
        selected: TranscriptionLanguage,
        targets: Set<String>,
    ): TranscriptionLanguage = if (isSelectable(selected, targets)) selected else OFF

    /**
     * The wire value the engines take: a language code, or empty for no
     * translation. Engines test this with `isEmpty()`, so "auto" must never
     * reach them — it would read as a language rather than as its absence.
     */
    fun target(selected: TranscriptionLanguage, targets: Set<String>): String =
        resolve(selected, targets).takeIf { it != OFF }?.wireValue.orEmpty()

    /**
     * What the picked target is called in a settings row.
     *
     * "Off" rather than "Automatic": the shared enum's own label describes
     * language detection, which is the opposite of what this row's default
     * means.
     *
     * [onDevice] separates the two ways this can be unavailable. Blaming the
     * model is only right when there is one: a gateway has no local model at
     * all, and the fix is a different screen.
     */
    fun summary(
        selected: TranscriptionLanguage,
        targets: Set<String>,
        onDevice: Boolean = true,
    ): String {
        if (!isSupported(targets)) {
            return if (onDevice) "Not supported by this model" else "Needs an on-device model"
        }
        val resolved = resolve(selected, targets)
        return if (resolved == OFF) "Off" else resolved.displayName
    }

    /**
     * Why the picker is limited, or null when it is not.
     *
     * The unsupported case is the important one. It is the only place the app
     * can explain that the language row above never translated anything, which
     * is the belief people arrive with after Whisper appeared to do it.
     */
    fun restriction(
        targets: Set<String>,
        onDevice: Boolean,
        needsExplicitSource: Boolean = false,
        sourceIsAutomatic: Boolean = false,
    ): String? {
        if (!onDevice) {
            return "Translation runs on this phone only. Your gateway transcribes " +
                "speech in the language it was spoken."
        }
        if (!isSupported(targets)) {
            return "This model transcribes what it hears and cannot translate. " +
                "Canary translates between English, German, Spanish and French; " +
                "the multilingual Whisper models translate into English. Picking a " +
                "language above never translated speech — it only tells the model " +
                "which language to expect."
        }
        // Sorted by the name shown, not by the code behind it: "German,
        // English, Spanish and French" is what sorting de/en/es/fr produces.
        val names = targets
            .mapNotNull { code -> TranscriptionLanguage.entries.firstOrNull { it.wireValue == code } }
            .map { it.displayName }
            .sorted()
        val list = when (names.size) {
            0, 1 -> names.joinToString()
            else -> names.dropLast(1).joinToString(", ") + " and " + names.last()
        }
        val coverage = "This model translates into $list. Speech in any other " +
            "language it covers is translated into your pick; the language above " +
            "stays what you are speaking."
        // The one way this setting can be wrong without looking wrong. Canary
        // is told what it is translating from, so Automatic resolves to English
        // and anyone speaking something else is translated out of a language
        // they never spoke.
        if (!needsExplicitSource || !sourceIsAutomatic) return coverage
        return coverage + " This model cannot work out what you are speaking, " +
            "so set Language to your own language first: on Automatic it " +
            "translates as though you had spoken English."
    }
}
