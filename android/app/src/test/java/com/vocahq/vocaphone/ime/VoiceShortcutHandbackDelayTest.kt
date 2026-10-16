package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.DictationPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A failed voice-shortcut dictation used to hand back on the same frame. */
class VoiceShortcutHandbackDelayTest {

    @Test
    fun aFailureStaysLongEnoughToRead() {
        assertTrue(VoiceShortcutIme.handbackDelayMillis(DictationPhase.FAILED) >= 2_000L)
    }

    @Test
    fun everyOtherHandbackIsImmediate() {
        assertEquals(0L, VoiceShortcutIme.handbackDelayMillis(DictationPhase.INSERTED))
        assertEquals(0L, VoiceShortcutIme.handbackDelayMillis(DictationPhase.IDLE))
    }
}
