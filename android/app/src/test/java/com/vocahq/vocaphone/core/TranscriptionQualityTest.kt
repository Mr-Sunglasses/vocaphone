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

    @Test
    fun `whisper fallback reaches rescue temperatures in at most two retries`() {
        assertEquals(0f, TranscriptionQuality.FAST.whisperTemperatureIncrement)
        assertEquals(1f, TranscriptionQuality.BALANCED.whisperTemperatureIncrement)
        assertEquals(0.5f, TranscriptionQuality.ACCURATE.whisperTemperatureIncrement)
    }
}
