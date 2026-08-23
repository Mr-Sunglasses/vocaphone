package com.vocahq.vocaphone.core

/**
 * Presentation only. No style adds, removes or substitutes a word, and numbers,
 * times, addresses and contractions are always left as the model transcribed
 * them. The raw values must stay identical to the gateway's `style` literals and
 * to the iOS client's `WritingStyle`.
 */
enum class WritingStyle(val wireValue: String) {
    RAW("raw"),
    CLEAN("clean"),
    FORMAL("formal"),
    CASUAL("casual"),
    VERY_CASUAL("very_casual"),
    EXCITED("excited");

    val displayName: String
        get() = when (this) {
            RAW -> "Raw"
            CLEAN -> "Clean"
            FORMAL -> "Formal"
            CASUAL -> "Casual"
            VERY_CASUAL -> "Very Casual"
            EXCITED -> "Excited"
        }

    val detail: String
        get() = when (this) {
            RAW -> "Exactly what the model returned, with nothing changed."
            CLEAN -> "Spacing tidied and a closing full stop. " +
                "Random capitals from the model are flattened; names like VocaPhone stay."
            FORMAL -> "Sentence capitalization and a closing full stop. " +
                "Mid-sentence Title Case from the model is flattened."
            CASUAL -> "Sentences kept, but no closing full stop."
            VERY_CASUAL -> "All lowercase, sentences joined with commas."
            EXCITED -> "Every statement ends with an exclamation mark."
        }

    /** A short worked example, so the choice is obvious before dictating. */
    val example: String
        get() = TranscriptStyler.apply(EXAMPLE_SOURCE, this)

    companion object {
        val DEFAULT = CASUAL

        /**
         * Unstyled model output the picker examples are produced from.
         * Clean and Formal only diverge when sentence starts are still lowercase.
         */
        internal const val EXAMPLE_SOURCE = "this is VocaPhone. it is a keyboard you talk to"

        fun fromWire(value: String?): WritingStyle =
            entries.firstOrNull { it.wireValue == value } ?: DEFAULT
    }
}
