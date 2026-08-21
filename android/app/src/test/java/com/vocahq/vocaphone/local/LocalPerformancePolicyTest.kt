package com.vocahq.vocaphone.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalPerformancePolicyTest {

    @Test
    fun `whisper worker count is capped for sustained phone inference`() {
        assertEquals(2, WhisperCpuConfig.whisperThreadCount(4, "base-q5_1"))
        assertEquals(6, WhisperCpuConfig.whisperThreadCount(8, "base-q5_1"))
        assertEquals(6, WhisperCpuConfig.whisperThreadCount(8, "small-q5_1"))
        assertEquals(4, WhisperCpuConfig.whisperThreadCount(8, "small"))
        assertEquals(4, WhisperCpuConfig.whisperThreadCount(16, "large-v3-q5_0"))
    }

    @Test
    fun `short dictations crop the encoder window instead of padding to thirty seconds`() {
        // A two-second dictation needs 100 units of context; the floor is what
        // keeps the decoder out of a repetition loop at that length.
        assertEquals(768, WhisperCpuConfig.whisperAudioContext(2 * 16000))
        assertEquals(768, WhisperCpuConfig.whisperAudioContext(5 * 16000))
        // Past the floor the window tracks the audio, with margin over the 550
        // units eleven seconds actually occupies.
        assertEquals(1100, WhisperCpuConfig.whisperAudioContext(11 * 16000))
    }

    @Test
    fun `long recordings keep whispers own window`() {
        // At fifteen seconds the margin already reaches the full window, and a
        // recording whisper splits into thirty-second windows must not be cropped.
        assertEquals(0, WhisperCpuConfig.whisperAudioContext(15 * 16000))
        assertEquals(0, WhisperCpuConfig.whisperAudioContext(120 * 16000))
    }

    @Test
    fun `only small whisper families use a cropped encoder window`() {
        assertTrue(LocalModelCatalog.find("tiny-q5_1")!!.cropsAudioContext)
        assertTrue(LocalModelCatalog.find("small-q5_1")!!.cropsAudioContext)
        assertFalse(LocalModelCatalog.find("medium-q5_0")!!.cropsAudioContext)
        assertFalse(LocalModelCatalog.find("large-v3-turbo-q5_0")!!.cropsAudioContext)
    }

    @Test
    fun `parakeet is not treated as heavier than a smaller whisper`() {
        val poco = DeviceProfile(
            totalRamGB = 6,
            cpuCores = 8,
            abi = "arm64-v8a",
            maxCpuKHz = 2_800_000,
            sherpaAvailable = true,
        )
        val parakeet = LocalModelCatalog.find("parakeet-tdt-0.6b-v3")!!
        val whisperBase = LocalModelCatalog.find("base-q5_1")!!
        val whisperSmall = LocalModelCatalog.find("small-q5_1")!!
        val whisperLarge = LocalModelCatalog.find("large-v3")!!
        assertTrue(parakeet.sizeBytes > whisperBase.sizeBytes)
        assertFalse(LocalModelCatalog.needsHeavierWarning(parakeet, poco))
        assertTrue(LocalModelCatalog.needsHeavierWarning(whisperLarge, poco))
        assertTrue(LocalModelCatalog.needsHeavierWarning(whisperSmall, poco))
        assertFalse(LocalModelCatalog.needsHeavierWarning(whisperBase, poco))
    }

    @Test
    fun `medium and large whisper models are marked slow on phones`() {
        assertTrue(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("large-v3")!!))
        assertTrue(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("large-v3-turbo")!!))
        assertTrue(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("large-v3-turbo-q5_0")!!))
        assertTrue(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("medium")!!))
        assertTrue(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("medium-q5_0")!!))
        assertTrue(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("medium-q8_0")!!))
        assertFalse(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("small-q5_1")!!))
        assertFalse(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("tiny-q5_1")!!))
        assertFalse(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("moonshine-tiny-en")!!))
        assertFalse(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("parakeet-tdt-0.6b-v3")!!))
    }
}
