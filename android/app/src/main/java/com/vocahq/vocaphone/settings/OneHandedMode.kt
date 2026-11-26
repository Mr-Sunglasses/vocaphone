package com.vocahq.vocaphone.settings

/**
 * Gboard's one-handed mode: the keys shrink toward one edge so a thumb on
 * that side reaches all of them. Phone portrait only; a tablet, a landscape
 * phone or an unfolded foldable ignores it (split is the wide-screen answer).
 */
enum class OneHandedMode(val storedValue: String) {
    OFF("off"),
    LEFT("left"),
    RIGHT("right"),
    ;

    val displayName: String
        get() = when (this) {
            OFF -> "Off"
            LEFT -> "Left"
            RIGHT -> "Right"
        }

    companion object {
        fun fromStored(value: String?): OneHandedMode =
            entries.firstOrNull { it.storedValue == value } ?: OFF
    }
}
