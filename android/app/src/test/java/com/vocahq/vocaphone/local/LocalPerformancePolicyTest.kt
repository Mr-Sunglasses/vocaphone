package com.vocahq.vocaphone.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalPerformancePolicyTest {

    @Test
    fun `whisper worker count is capped for sustained phone inference`() {
        assertEquals(2, WhisperCpuConfig.whisperThreadCount(4, "base-q8_0"))
        assertEquals(6, WhisperCpuConfig.whisperThreadCount(8, "base-q8_0"))
        assertEquals(6, WhisperCpuConfig.whisperThreadCount(8, "small-q8_0"))
        assertEquals(4, WhisperCpuConfig.whisperThreadCount(16, "large-v3-turbo-q8_0"))
        // No full-precision build is in the catalog any more, but the ceiling
        // turns on how long a model runs rather than on its name, so a build
        // without a `-q` still gets four workers if one is ever added back.
        assertEquals(4, WhisperCpuConfig.whisperThreadCount(8, "small"))
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
        assertTrue(LocalModelCatalog.find("tiny-q8_0")!!.cropsAudioContext)
        assertTrue(LocalModelCatalog.find("base-q8_0")!!.cropsAudioContext)
        assertTrue(LocalModelCatalog.find("small-q8_0")!!.cropsAudioContext)
        assertFalse(LocalModelCatalog.find("large-v3-turbo-q8_0")!!.cropsAudioContext)
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
        val whisperBase = LocalModelCatalog.find("base-q8_0")!!
        val whisperSmall = LocalModelCatalog.find("small-q8_0")!!
        val whisperLarge = LocalModelCatalog.find("large-v3-turbo-q8_0")!!
        assertTrue(parakeet.sizeBytes > whisperBase.sizeBytes)
        assertFalse(LocalModelCatalog.needsHeavierWarning(parakeet, poco))
        assertTrue(LocalModelCatalog.needsHeavierWarning(whisperLarge, poco))
        assertTrue(LocalModelCatalog.needsHeavierWarning(whisperSmall, poco))
        assertFalse(LocalModelCatalog.needsHeavierWarning(whisperBase, poco))
    }

    @Test
    fun `large whisper models are marked slow on phones`() {
        // Medium is gone from the catalog; large-v3-turbo is the only rung left
        // above the class this mark starts at.
        assertTrue(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("large-v3-turbo-q8_0")!!))
        assertFalse(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("small-q8_0")!!))
        assertFalse(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("base-q8_0")!!))
        assertFalse(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("tiny-q8_0")!!))
        assertFalse(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("moonshine-v2-tiny-en")!!))
        assertFalse(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("parakeet-tdt-0.6b-v3")!!))
    }
}
