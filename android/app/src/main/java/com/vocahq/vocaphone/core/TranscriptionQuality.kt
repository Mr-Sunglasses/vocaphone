package com.vocahq.vocaphone.core

/**
 * How much decoding work an on-device model may spend on one dictation.
 *
 * This only governs the local engines. The gateway decides for itself, and a
 * phone is where the trade-off actually bites: the same model that finishes a
 * sentence instantly on a desktop can keep a mid-range phone busy long enough
 * that the user notices, so the choice belongs to them rather than to a
 * constant somewhere.
 *
 * The stored values must stay identical to the iOS client's
 * `TranscriptionQuality`, because both write into the same paired setup.
 */
enum class TranscriptionQuality(val storedValue: String) {
    FAST("fast"),
    BALANCED("balanced"),
    ACCURATE("accurate"),
    ;

    val displayName: String
        get() = when (this) {
            FAST -> "Fast"
            BALANCED -> "Balanced"
            ACCURATE -> "Accurate"
        }

    val detail: String
        get() = when (this) {
            FAST -> "Quickest result. Skips the retries that rescue a hard passage."
            BALANCED -> "Beam search where it is cheap, and a retry when a window looks wrong."
            ACCURATE -> "Wider search for difficult speech. Can be 2-3x slower on older phones."
        }

    /**
     * whisper.cpp beam width, or zero for greedy sampling.
     *
     * Beam search is the standard accuracy win over greedy, and also the
     * standard way to make decoding take twice as long, so only Accurate asks
     * for it. Three keeps most of the accuracy benefit without making a
     * constrained phone pay for five decoder passes per token.
     */
    val whisperBeamSize: Int
        get() = when (this) {
            FAST, BALANCED -> 0
            ACCURATE -> 3
        }

    /**
     * Temperature step for a window whose first decode looks degenerate.
     *
     * whisper.cpp keeps adding this value until it reaches 1.0. Its usual 0.2
     * therefore permits five retries, not one, and every retry reruns the whole
     * decoder. Balanced jumps straight to one rescue pass; Accurate tries the
     * midpoint first but is still capped at two retries.
     */
    val whisperTemperatureIncrement: Float
        get() = when (this) {
            FAST -> 0f
            BALANCED -> 1f
            ACCURATE -> 0.5f
        }

    /**
     * What to ask a sherpa model for *if its family supports beam search*.
     *
     * Never pass this to a recognizer without checking
     * `SherpaFamily.supportsBeamSearch` first: the families that do not support
     * it terminate the process rather than falling back.
     */
    val sherpaDecodingMethod: String
        get() = when (this) {
            FAST -> "greedy_search"
            BALANCED, ACCURATE -> "modified_beam_search"
        }

    /** Beam width for [sherpaDecodingMethod]; ignored by `greedy_search`. */
    val sherpaMaxActivePaths: Int
        get() = when (this) {
            FAST -> 1
            BALANCED -> 4
            ACCURATE -> 8
        }

    companion object {
        /**
         * Balanced rather than Fast: the two knobs it turns on are the ones that
         * pay for themselves, and a first dictation that is wrong is a worse
         * introduction than one that took an extra moment.
         */
        val DEFAULT = BALANCED

        fun fromStored(value: String?): TranscriptionQuality =
            entries.firstOrNull { it.storedValue == value } ?: DEFAULT
    }
}
