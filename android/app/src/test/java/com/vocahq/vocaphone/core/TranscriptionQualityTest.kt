package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Test

class TranscriptionQualityTest {

    @Test
    fun `accurate whisper uses a bounded beam`() {
        assertEquals(0, TranscriptionQuality.FAST.whisperBeamSize)
        assertEquals(0, TranscriptionQuality.BALANCED.whisperBeamSize)
        assertEquals(3, TranscriptionQuality.ACCURATE.whisperBeamSize)
    }
}
