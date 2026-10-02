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

    /**
     * Which category Automatic should ask for, given the types attached now.
     * Automatic keeps Bluetooth playback out of call mode by using the built-in
     * microphone when a headset is connected. Other inputs keep Android's routing.
     * Bluetooth microphone capture remains an explicit choice.
     */
    fun preferredCategory(
        preference: MicrophonePreference,
        attachedTypes: Collection<Int>,
    ): MicrophonePreference? {
        if (preference == MicrophonePreference.AUTOMATIC) {
            return MicrophonePreference.PHONE.takeIf {
                attachedTypes.any { it in deviceTypes(MicrophonePreference.BLUETOOTH) } &&
                    attachedTypes.any { it in deviceTypes(MicrophonePreference.PHONE) }
            }
        }
        return preference.takeIf { attachedTypes.any { type -> type in deviceTypes(it) } }
    }

    /** The attached input matching [preference], or null when none is. */
    fun match(manager: AudioManager, preference: MicrophonePreference): AudioDeviceInfo? {
        val inputs = manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        val attached = inputs.map { it.type } + if (preference == MicrophonePreference.AUTOMATIC) {
            manager.availableCommunicationDevices.map { it.type }
        } else {
            emptyList()
        }
        val resolved = preferredCategory(preference, attached) ?: return null
        val types = deviceTypes(resolved)
        if (types.isEmpty()) return null
        return inputs.firstOrNull { it.type in types }
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
        val types = deviceTypes(MicrophonePreference.BLUETOOTH)
        if (!requestsCommunicationRoute(preference)) return null
        return manager.availableCommunicationDevices.firstOrNull { it.type in types }
    }

    internal fun requestsCommunicationRoute(preference: MicrophonePreference): Boolean =
        preference == MicrophonePreference.BLUETOOTH

    /** The user-facing name of a route, for the "Input in use" line. */
    fun describe(device: AudioDeviceInfo): String {
        val kind = categoryOf(device.type)?.displayName ?: when (device.type) {
            AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> "System audio"
            else -> "External microphone"
        }
        val name = device.productName?.toString()?.trim().orEmpty()
        return if (name.isEmpty() || name.equals(kind, ignoreCase = true)) kind else "$kind ($name)"
    }
}
