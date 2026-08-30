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

        // Sherpa. Canary is both smaller and more accurate than Moonshine Base
        // (207 MB at 7.12 average WER against 287 MB at 10.07) and covers three
        // more languages, so it takes both of the rows it replaced.
        put("moonshine-base-en", listOf("canary-180m-flash", "moonshine-tiny-en"))
        put("fast-conformer-ctc-4-lang", listOf("canary-180m-flash"))
        put("dolphin-base-ctc", listOf("dolphin-small-ctc"))
        // Same weights family, new export: v3 with punctuation. The id changed
        // rather than the pins so an already-downloaded v2 directory is an
        // unknown model to be swept, not a SHA-256 mismatch on a known one.
        put("giga-am-ctc-ru", listOf("giga-am-ctc-v3-ru"))
    }

    /** Whether [id] names something the catalog used to ship and no longer does. */
    fun isRetired(id: String): Boolean = id in replacements

    /**
     * The id [stored] should become, or `stored` unchanged when it is still in
     * the catalog and nothing needs to happen.
     *
     * Returns null only when the selection is retired and no replacement fits
     * this device, which is the one case where falling through to the ordinary
     * recommendation is the right answer.
     */
    fun replacementFor(
        stored: String,
        totalRamGB: Long,
        sherpaAvailable: Boolean = LocalModelCatalog.sherpaAvailable,
    ): String? {
        if (stored.isEmpty()) return stored
        if (LocalModelCatalog.find(stored) != null) return stored
        val candidates = replacements[stored] ?: return null
        return candidates.firstNotNullOfOrNull { id ->
            LocalModelCatalog.find(id)
                ?.takeIf { LocalModelCatalog.isUsableOnDevice(it, totalRamGB, sherpaAvailable) }
                ?.id
        }
    }
}
