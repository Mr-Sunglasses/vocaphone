package io.github.mrsunglasses.localflow.audio

import android.media.AudioDeviceInfo
import io.github.mrsunglasses.localflow.core.MicrophonePreference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InputDevicesTest {

    @Test
    fun `automatic claims no device of its own`() {
        assertTrue(InputDevices.deviceTypes(MicrophonePreference.AUTOMATIC).isEmpty())
    }

    @Test
    fun `every other preference names at least one device type`() {
        MicrophonePreference.entries
            .filterNot { it == MicrophonePreference.AUTOMATIC }
            .forEach { preference ->
                assertTrue(
                    "${preference.name} matches no device type",
                    InputDevices.deviceTypes(preference).isNotEmpty(),
                )
            }
    }

    @Test
    fun `no device type is claimed by two preferences`() {
        val claimed = mutableSetOf<Int>()
        MicrophonePreference.entries.forEach { preference ->
            InputDevices.deviceTypes(preference).forEach { type ->
                assertTrue("device type $type is claimed twice", claimed.add(type))
            }
        }
    }

    @Test
    fun `each device type resolves back to the preference that claims it`() {
        assertEquals(
            MicrophonePreference.PHONE,
            InputDevices.categoryOf(AudioDeviceInfo.TYPE_BUILTIN_MIC),
        )
        assertEquals(
            MicrophonePreference.WIRED,
            InputDevices.categoryOf(AudioDeviceInfo.TYPE_WIRED_HEADSET),
        )
        assertEquals(
            MicrophonePreference.BLUETOOTH,
            InputDevices.categoryOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO),
        )
        assertEquals(
            MicrophonePreference.BLUETOOTH,
            InputDevices.categoryOf(AudioDeviceInfo.TYPE_BLE_HEADSET),
        )
        assertEquals(
            MicrophonePreference.USB,
            InputDevices.categoryOf(AudioDeviceInfo.TYPE_USB_HEADSET),
        )
        assertEquals(
            MicrophonePreference.USB,
            InputDevices.categoryOf(AudioDeviceInfo.TYPE_USB_DEVICE),
        )
    }

    @Test
    fun `an unmapped device belongs to no category`() {
        assertNull(InputDevices.categoryOf(AudioDeviceInfo.TYPE_REMOTE_SUBMIX))
        assertNull(InputDevices.categoryOf(AudioDeviceInfo.TYPE_TELEPHONY))
    }

    @Test
    fun `automatic is offered even when the phone reports no input at all`() {
        assertEquals(setOf(MicrophonePreference.AUTOMATIC), InputDevices.available(emptyList()))
    }

    @Test
    fun `attached hardware decides which preferences are offered`() {
        val available = InputDevices.available(
            listOf(
                AudioDeviceInfo.TYPE_BUILTIN_MIC,
                AudioDeviceInfo.TYPE_USB_DEVICE,
                AudioDeviceInfo.TYPE_REMOTE_SUBMIX,
            )
        )

        assertEquals(
            setOf(
                MicrophonePreference.AUTOMATIC,
                MicrophonePreference.PHONE,
                MicrophonePreference.USB,
            ),
            available,
        )
    }

    @Test
    fun `a category attached twice is still offered once`() {
        val available = InputDevices.available(
            listOf(AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE),
        )

        assertEquals(
            setOf(MicrophonePreference.AUTOMATIC, MicrophonePreference.USB),
            available,
        )
    }
}
