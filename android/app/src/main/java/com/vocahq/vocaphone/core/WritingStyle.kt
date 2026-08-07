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
            CLEAN -> "Spacing tidied and a closing full stop. Capitalization untouched."
            FORMAL -> "Sentence capitalization and a closing full stop."
            CASUAL -> "Sentences kept, but no closing full stop."
            VERY_CASUAL -> "All lowercase, sentences joined with commas."
            EXCITED -> "Every statement ends with an exclamation mark."
        }

    /** A short worked example, so the choice is obvious before dictating. */
    val example: String
        get() = when (this) {
            RAW, CLEAN, FORMAL -> "I don't think it's ready. It cost $1,200."
            CASUAL -> "I don't think it's ready. It cost $1,200"
            VERY_CASUAL -> "i don't think it's ready, it cost $1,200"
            EXCITED -> "I don't think it's ready! It cost $1,200!"
        }

    companion object {
        val DEFAULT = CASUAL

        fun fromWire(value: String?): WritingStyle =
            entries.firstOrNull { it.wireValue == value } ?: DEFAULT
    }
}
