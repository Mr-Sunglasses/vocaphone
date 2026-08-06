package io.github.mrsunglasses.localflow.ui

import io.github.mrsunglasses.localflow.core.MicrophonePreference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MicrophoneStatusTest {

    @Test
    fun `before any dictation, automatic admits the input is not decided yet`() {
        val status = MicrophoneStatus()

        assertEquals(
            "Selected when recording starts",
            status.inUseLabel(MicrophonePreference.AUTOMATIC),
        )
    }

    @Test
    fun `before any dictation, an explicit choice is shown as what was asked for`() {
        val status = MicrophoneStatus()

        assertEquals("USB microphone", status.inUseLabel(MicrophonePreference.USB))
    }

    @Test
    fun `while recording, the live route is reported unqualified`() {
        val status = MicrophoneStatus(route = "USB microphone — Shure MV7", recording = true)

        assertEquals(
            "USB microphone — Shure MV7",
            status.inUseLabel(MicrophonePreference.USB),
        )
    }

    /** The route is only knowable while capture holds it, so afterwards it is history. */
    @Test
    fun `after recording, the same route is marked as the last one used`() {
        val status = MicrophoneStatus(route = "Phone microphone", recording = false)

        assertEquals("Last used: Phone microphone", status.inUseLabel(MicrophonePreference.PHONE))
    }

    @Test
    fun `a route Android chose over the request is still what gets reported`() {
        val status = MicrophoneStatus(route = "Phone microphone", recording = true)

        assertEquals("Phone microphone", status.inUseLabel(MicrophonePreference.BLUETOOTH))
    }

    @Test
    fun `the choice is locked for exactly as long as the microphone is held`() {
        assertTrue(MicrophoneStatus(recording = false).changeable)
        assertFalse(MicrophoneStatus(recording = true).changeable)
    }
}
