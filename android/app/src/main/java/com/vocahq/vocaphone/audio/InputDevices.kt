package com.vocahq.vocaphone.audio

import android.media.AudioDeviceInfo
import android.media.AudioManager
import com.vocahq.vocaphone.core.MicrophonePreference

/**
 * Translates between [MicrophonePreference] categories and the concrete
 * [AudioDeviceInfo] entries Android reports, so the rest of the app never has
 * to reason about raw device-type constants.
 */
object InputDevices {

    /**
     * The device types a preference is satisfied by. [MicrophonePreference.AUTOMATIC]
     * names no device: it means "do not ask", which is not the same as matching
     * everything and must never resolve to a preferred device.
     */
    fun deviceTypes(preference: MicrophonePreference): Set<Int> = when (preference) {
        MicrophonePreference.AUTOMATIC -> emptySet()
        MicrophonePreference.PHONE -> setOf(AudioDeviceInfo.TYPE_BUILTIN_MIC)
        MicrophonePreference.WIRED -> setOf(AudioDeviceInfo.TYPE_WIRED_HEADSET)
        MicrophonePreference.BLUETOOTH -> setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )

        MicrophonePreference.USB -> setOf(
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_ACCESSORY,
        )
    }

    /** The category a reported device belongs to, or null for anything unmapped. */
    fun categoryOf(deviceType: Int): MicrophonePreference? = MicrophonePreference.entries
        .firstOrNull { it != MicrophonePreference.AUTOMATIC && deviceType in deviceTypes(it) }

    /**
     * Which categories the hardware attached right now can satisfy. Automatic is
     * always offered — it is the absence of a request, so it cannot be unavailable.
     */
    fun available(deviceTypes: Collection<Int>): Set<MicrophonePreference> = buildSet {
        add(MicrophonePreference.AUTOMATIC)
        deviceTypes.mapNotNullTo(this, ::categoryOf)
    }

    /** As [available], read from the platform. */
    fun available(manager: AudioManager): Set<MicrophonePreference> = available(
        manager.getDevices(AudioManager.GET_DEVICES_INPUTS).map { it.type } +
            manager.availableCommunicationDevices.map { it.type },
    )

    /** The attached input matching [preference], or null when none is. */
    fun match(manager: AudioManager, preference: MicrophonePreference): AudioDeviceInfo? {
        val types = deviceTypes(preference)
        if (types.isEmpty()) return null
        return manager.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.type in types }
    }

    /**
     * Reaching a Bluetooth headset's microphone means putting the headset into
     * call mode, which Android only does through the communication device rather
     * than through [android.media.AudioRecord.setPreferredDevice] alone.
     */
    fun communicationMatch(
        manager: AudioManager,
        preference: MicrophonePreference,
    ): AudioDeviceInfo? {
        if (preference != MicrophonePreference.BLUETOOTH) return null
        val types = deviceTypes(preference)
        return manager.availableCommunicationDevices.firstOrNull { it.type in types }
    }

    /** The user-facing name of a route, for the "Input in use" line. */
    fun describe(device: AudioDeviceInfo): String {
        val kind = categoryOf(device.type)?.displayName ?: when (device.type) {
            AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> "System audio"
            else -> "External microphone"
        }
        val name = device.productName?.toString()?.trim().orEmpty()
        return if (name.isEmpty() || name.equals(kind, ignoreCase = true)) kind else "$kind — $name"
    }
}
