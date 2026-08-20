package com.vocahq.vocaphone.core

/**
 * Which microphone a dictation asks Android for.
 *
 * Mirrors the iOS client's `MicrophonePreference`, which offers Automatic and
 * the built-in microphone; the remaining entries are the routes Android
 * hardware actually exposes separately.
 *
 * A category is stored rather than a device id because Android issues a fresh
 * id every time a headset is reconnected: a saved id stops matching the moment
 * the user unplugs and plugs back in, while "the USB microphone" stays true.
 */
enum class MicrophonePreference(val storedValue: String) {
    AUTOMATIC("automatic"),
    PHONE("phone"),
    WIRED("wired"),
    BLUETOOTH("bluetooth"),
    USB("usb"),
    ;

    val displayName: String
        get() = when (this) {
            AUTOMATIC -> "Automatic"
            PHONE -> "Phone microphone"
            WIRED -> "Wired headset"
            BLUETOOTH -> "Bluetooth headset"
            USB -> "USB microphone"
        }

    val detail: String
        get() = when (this) {
            AUTOMATIC ->
                "Uses a Bluetooth headset when one is connected. Otherwise uses " +
                    "this phone's microphone."
            PHONE -> "Always use the microphone built into this phone."
            WIRED -> "Always use the microphone on a wired headset."
            BLUETOOTH ->
                "Always use the microphone on a Bluetooth headset. Android puts " +
                    "the headset into call mode, so music playback drops in quality " +
                    "while you dictate."
            USB -> "Always use a USB microphone or headset."
        }

    /** Shown when the preference is stored but nothing matching is attached. */
    val unavailableDetail: String
        get() = when (this) {
            AUTOMATIC -> detail
            PHONE -> "No built-in microphone was reported. Recording uses whatever Android offers."
            WIRED -> "No wired headset is connected. Recording uses whatever Android offers."
            BLUETOOTH -> "No Bluetooth headset is connected. Recording uses whatever Android offers."
            USB -> "No USB microphone is connected. Recording uses whatever Android offers."
        }

    companion object {
        val DEFAULT = AUTOMATIC

        /** An install that predates the setting, or one whose hardware category was
         *  dropped, reads back as Automatic rather than failing to load settings. */
        fun fromStored(value: String?): MicrophonePreference =
            entries.firstOrNull { it.storedValue == value } ?: DEFAULT
    }
}
