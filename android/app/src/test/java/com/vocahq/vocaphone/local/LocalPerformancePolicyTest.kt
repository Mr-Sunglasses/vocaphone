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
    fun `parakeet is not treated as heavier than a smaller whisper`() {
        val parakeet = LocalModelCatalog.find("parakeet-tdt-0.6b-v3")!!
        val whisperBase = LocalModelCatalog.find("base-q5_1")!!
        val whisperLarge = LocalModelCatalog.find("large-v3")!!
        assertTrue(parakeet.sizeBytes > whisperBase.sizeBytes)
        assertTrue(!LocalModelCatalog.needsHeavierWarning(parakeet, whisperBase))
        assertTrue(LocalModelCatalog.needsHeavierWarning(whisperLarge, parakeet))
        assertTrue(!LocalModelCatalog.needsHeavierWarning(whisperBase, parakeet))
    }
}
