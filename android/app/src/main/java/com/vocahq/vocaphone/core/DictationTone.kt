package com.vocahq.vocaphone.core

/**
 * Family start/stop cues shared with VocaWin. The stored id is what Settings
 * writes; a missing value is a new install, not Off.
 */
enum class DictationTone(val id: String) {
    LIFT("lift"),
    FLICK("flick"),
    EMBER("ember"),
    STEP("step"),
    VOCA("voca"),
    SOFT("soft"),
    CHIRP("chirp"),
    SCALE("scale"),
    DROP("drop"),
    GLASS("glass"),
    OFF("off"),
    ;

    val displayName: String
        get() = when (this) {
            LIFT -> "Lift"
            FLICK -> "Flick"
            EMBER -> "Ember"
            STEP -> "Step"
            VOCA -> "Voca"
            SOFT -> "Soft"
            CHIRP -> "Chirp"
            SCALE -> "Scale"
            DROP -> "Drop"
            GLASS -> "Glass"
            OFF -> "Off"
        }

    val playsCues: Boolean get() = this != OFF

    companion object {
        val DEFAULT = VOCA

        /**
         * Null or blank is an unset preference and becomes [DEFAULT]. Off is
         * only Off when that id was actually saved.
         */
        fun fromStored(value: String?): DictationTone {
            if (value.isNullOrBlank()) return DEFAULT
            return entries.firstOrNull { it.id.equals(value, ignoreCase = true) } ?: DEFAULT
        }
    }
}
