package com.vocahq.vocaphone.local

/**
 * Where a stored selection goes when the model it names has left the catalog.
 *
 * A model id is persisted verbatim in `local_model_id`, so shrinking the catalog
 * strands everyone who had picked one of the removed rows. Without this they
 * fall through `LocalModelCatalog.find` to null and the app quietly re-derives a
 * first-run recommendation -- which, on a phone that was deliberately running
 * Whisper Medium, means landing on Tiny. The person chose a heavier model on
 * purpose; the migration has to respect that and hand them the nearest thing
 * still shipping, not the smallest.
 *
 * Each entry is a preference *list* rather than one id, because "nearest" has to
 * survive the device: a 4 GB phone on `medium-q5_0` cannot hold the 6 GB
 * `large-v3-turbo-q8_0` that replaces it on quality, so the fallback steps down
 * the surviving ladder instead of off it. [replacementFor] resolves the list
 * against what the device can actually run.
 *
 * Mirrors `RetiredLocalModels.swift`. The two catalogs differ -- whisper.cpp
 * GGML here, Core ML there -- so the tables differ; the rule does not.
 */
object RetiredModels {

    /**
     * Retired id to its replacements, best first.
     *
     * The whisper rows collapse three axes that no longer exist in the catalog:
     * quantization (q5 and F16 are gone, see the `whisper` list in
     * [LocalModelCatalog]), the `.en` builds, and the sizes that were never
     * viable on a phone. Everything therefore lands on the Q8_0 build of the
     * same rung, except the sizes with no surviving rung of their own -- medium
     * and the two full large builds -- which move up to `large-v3-turbo-q8_0`
     * and step down to `small-q8_0` where that will not fit.
     */
    val replacements: Map<String, List<String>> = buildMap {
        // Whisper: same rung, Q8_0 build.
        listOf("tiny-q5_1", "tiny", "tiny.en-q5_1", "tiny.en-q8_0", "tiny.en")
            .forEach { put(it, listOf("tiny-q8_0")) }
        listOf("base-q5_1", "base", "base.en-q5_1", "base.en-q8_0", "base.en")
            .forEach { put(it, listOf("base-q8_0", "tiny-q8_0")) }
        listOf("small-q5_1", "small", "small.en-q5_1", "small.en-q8_0", "small.en")
            .forEach { put(it, listOf("small-q8_0", "base-q8_0")) }

        // Whisper: no surviving rung, so promote and let the device decide.
        listOf(
            "medium-q5_0", "medium-q8_0", "medium",
            "medium.en-q5_0", "medium.en-q8_0", "medium.en",
            "large-v3-turbo-q5_0", "large-v3-turbo",
            "large-v3-q5_0", "large-v3",
            "large-v2-q5_0", "large-v2-q8_0", "large-v2",
        ).forEach { put(it, listOf("large-v3-turbo-q8_0", "small-q8_0", "base-q8_0")) }

        // Sherpa. Canary covers the same four languages as the Fast Conformer
        // it replaces, in 207 MB against 461 MB, with better WER and the only
        // speech-translation path in the catalog.
        put("fast-conformer-ctc-4-lang", listOf("canary-180m-flash"))
        // Every Moonshine build retires onto the 110M Parakeet. v2 returns
        // nothing for a window of 9.4 s or more, and on the clips it can decode
        // it is still the less accurate model (LibriSpeech test-other 9.16
        // against 6.20); v1 was already behind v2.
        listOf("moonshine-tiny-en", "moonshine-base-en", "moonshine-v2-tiny-en", "moonshine-v2-base-en")
            .forEach { put(it, listOf("parakeet-tdt-ctc-110m-en")) }
        // Both Dolphin builds prefer Whisper, then SenseVoice. Dolphin Small
        // listed English but returned nothing for it, nor for German, and
        // answered French in Persian script. Large v3 covers the languages
        // Dolphin claimed, including Cantonese; Small does not cover Cantonese,
        // so a phone that cannot hold Large steps to SenseVoice when that still
        // covers what the user speaks. Whisper remains the fdroid path because
        // SenseVoice needs sherpa.
        listOf("dolphin-base-ctc", "dolphin-small-ctc")
            .forEach { put(it, listOf("large-v3-turbo-q8_0", "small-q8_0", "sense-voice")) }
        // SenseVoice is the stronger Mandarin model, also covers Cantonese,
        // and needs the same memory.
        put("paraformer-zh-small", listOf("sense-voice"))
        // Same weights family, new export: v3 with punctuation. The id changed
        // rather than the pins so an already-downloaded v2 directory is an
        // unknown model to be swept, not a SHA-256 mismatch on a known one.
        put("giga-am-ctc-ru", listOf("giga-am-v3-ru"))
        // Only ever on the unmerged branch, but testers have it downloaded.
        put("giga-am-ctc-v3-ru", listOf("giga-am-v3-ru"))
    }

    /** Whether [id] names something the catalog used to ship and no longer does. */
    fun isRetired(id: String): Boolean = id in replacements

    /**
     * What should happen to a stored selection, decided without touching storage
     * so it can be reasoned about and tested on its own.
     */
    sealed interface Outcome {
        /** The selection still names a model in the catalog. */
        data object Unchanged : Outcome

        /** The selection was retired and this is its nearest surviving model. */
        data class Replaced(val id: String) : Outcome

        /**
         * The selection was retired and nothing that replaces it fits this
         * device. On-device transcription has to be turned off along with it;
         * see [resolve].
         */
        data object Cleared : Outcome
    }

    /**
     * What to do with [stored] on this device.
     *
     * [Outcome.Cleared] is the case worth being careful about. A 2 GB phone on
     * `dolphin-base-ctc` with sherpa unavailable has nothing to move to --
     * Whisper Large and Small need more memory, and SenseVoice is not on that
     * build -- and clearing the model alone would leave on-device transcription
     * still switched on with nothing behind it. `deliverLocal` would then
     * record the audio and fail at the end of every dictation with "Choose and
     * download an on-device model first", forever. Turning the switch off with
     * the selection sends the same person to `GATEWAY_NOT_CONFIGURED` setup
     * *before* recording instead, which is the honest answer and the
     * actionable one.
     *
     * [languages] is what the user actually speaks: empty means unknown, and
     * then the first fitting candidate wins, which is how English-only and
     * legacy migrations behave. When it is set, a fitting candidate that
     * covers every requested language is preferred, so Cantonese on a 3 GB
     * phone lands on SenseVoice instead of Whisper Small. If none of the
     * fitting candidates cover the languages, the first fitting one is kept
     * so the phone is not left without a model.
     *
     * [primaryLanguage] is the one the user chose to dictate in, null for
     * Automatic, and it outranks the rest: [languages] can only break a tie
     * between models that keep it. A Cantonese speaker who also has a Hindi
     * keyboard on a 3 GB phone still lands on SenseVoice, not on Whisper Small,
     * which has Hindi but not Cantonese. And when this ladder could serve that
     * language but nothing that fits does -- Hindi on a 2 GB phone, where only
     * SenseVoice fits -- the selection is cleared rather than swapped for a
     * model without it. A ladder that never covered the language, such as
     * Moonshine's English-only one under a stale German setting, ignores it.
     */
    fun resolve(
        stored: String,
        totalRamGB: Long,
        sherpaAvailable: Boolean = LocalModelCatalog.sherpaAvailable,
        languages: Collection<String> = emptyList(),
        primaryLanguage: String? = null,
    ): Outcome {
        if (stored.isEmpty()) return Outcome.Unchanged
        if (LocalModelCatalog.find(stored) != null) return Outcome.Unchanged
        val candidates = replacements[stored] ?: return Outcome.Unchanged
        val ladder = candidates.mapNotNull(LocalModelCatalog::find)
        var pool = ladder.filter { LocalModelCatalog.isUsableOnDevice(it, totalRamGB, sherpaAvailable) }
        val primary = catalogLanguageCode(primaryLanguage)
        if (primary != null && ladder.any { it.coversLanguage(primary) }) {
            pool = pool.filter { it.coversLanguage(primary) }
        }
        val covering = pool.filter { it.coversAll(languages.toList()) }
        val chosen = covering.firstOrNull() ?: pool.firstOrNull()
        return chosen?.id?.let(Outcome::Replaced) ?: Outcome.Cleared
    }

    /** Apply the launch decision through the settings store's atomic writes. */
    suspend fun migrate(
        stored: String,
        totalRamGB: Long,
        sherpaAvailable: Boolean = LocalModelCatalog.sherpaAvailable,
        languages: Collection<String> = emptyList(),
        primaryLanguage: String? = null,
        replace: suspend (String) -> Unit,
        clear: suspend () -> Unit,
    ): Outcome = resolve(stored, totalRamGB, sherpaAvailable, languages, primaryLanguage).also { outcome ->
        when (outcome) {
            is Outcome.Unchanged -> Unit
            is Outcome.Replaced -> replace(outcome.id)
            is Outcome.Cleared -> clear()
        }
    }

    /**
     * The id [stored] should become, or null when it is retired and nothing
     * fits. Kept for callers that only want the replacement.
     *
     * An id in neither the catalog nor [replacements] comes back unchanged
     * rather than null: this build does not recognise it, which is what a
     * downgrade from a newer one looks like, and discarding a selection on that
     * basis would lose a model the user is about to want back. The same reason
     * `LocalModelManager.deleteRetiredModelFiles` deletes only named ids.
     */
    fun replacementFor(
        stored: String,
        totalRamGB: Long,
        sherpaAvailable: Boolean = LocalModelCatalog.sherpaAvailable,
        languages: Collection<String> = emptyList(),
    ): String? = when (val outcome = resolve(stored, totalRamGB, sherpaAvailable, languages)) {
        is Outcome.Unchanged -> stored
        is Outcome.Replaced -> outcome.id
        is Outcome.Cleared -> null
    }
}
