package com.vocahq.vocaphone.audio

import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Test

class CaptureFocusTest {
    @Test
    fun `the phone's own microphone lets music duck instead of pausing`() {
        assertEquals(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK, CaptureFocus.gain(communicationRoute = false))
    }

    @Test
    fun `a Bluetooth headset microphone keeps exclusive focus`() {
        assertEquals(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE, CaptureFocus.gain(communicationRoute = true))
    }
}
