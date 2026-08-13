package com.vocahq.vocaphone.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalPerformancePolicyTest {

    @Test
    fun `whisper worker count is capped for sustained phone inference`() {
        assertEquals(2, WhisperCpuConfig.whisperThreadCount(4))
        assertEquals(6, WhisperCpuConfig.whisperThreadCount(8))
        assertEquals(6, WhisperCpuConfig.whisperThreadCount(16))
    }

    @Test
    fun `short dictations crop the encoder window instead of padding to thirty seconds`() {
        // A two-second dictation needs 100 units of context; the floor is what
        // keeps the decoder out of a repetition loop at that length.
        assertEquals(448, WhisperCpuConfig.whisperAudioContext(2 * 16000))
        assertEquals(448, WhisperCpuConfig.whisperAudioContext(5 * 16000))
        // Past the floor the window tracks the audio, with margin over the 550
        // units eleven seconds actually occupies.
        assertEquals(825, WhisperCpuConfig.whisperAudioContext(11 * 16000))
    }

    @Test
    fun `long recordings keep whispers own window`() {
        // At twenty seconds the margin already reaches the full window, and a
        // recording whisper splits into thirty-second windows must not be cropped.
        assertEquals(0, WhisperCpuConfig.whisperAudioContext(20 * 16000))
        assertEquals(0, WhisperCpuConfig.whisperAudioContext(120 * 16000))
    }

    @Test
    fun `older high ram phone receives a conservative recommendation`() {
        assertEquals("base-q5_1", LocalModelCatalog.recommended(8, 0).id)
        assertTrue(
            LocalModelCatalog.usableOnDevice(8).any { it.id == "large-v3-turbo-q5_0" },
        )
    }

    @Test
    fun `large models remain recommendations for declared performance class devices`() {
        assertEquals("large-v3-turbo-q5_0", LocalModelCatalog.recommended(8, 31).id)
        assertEquals("large-v3-turbo", LocalModelCatalog.recommended(12, 34).id)
    }
}
