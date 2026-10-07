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

    /** Peak clocks in kHz, as each core's `cpuinfo_max_freq` publishes them. */
    private fun cores(vararg clusters: Pair<Int, Int>): List<Int> =
        clusters.flatMap { (count, khz) -> List(count) { khz } }

    @Test
    fun `performance cores are the ones clocked near the fastest`() {
        // Snapdragon 845, the POCO F1: 4 x 2.8 GHz + 4 x 1.77 GHz.
        assertEquals(
            4,
            WhisperCpuConfig.performanceCoreCount(cores(4 to 1_766_400, 4 to 2_803_200)),
        )
        // Snapdragon 855: one prime, three big, four efficiency.
        assertEquals(
            4,
            WhisperCpuConfig.performanceCoreCount(
                cores(4 to 1_785_600, 3 to 2_419_200, 1 to 2_841_600),
            ),
        )
        // Tensor G1, the Pixel 6a: 2 x X1 + 2 x A76 + 4 x A55.
        assertEquals(
            4,
            WhisperCpuConfig.performanceCoreCount(
                cores(4 to 1_803_000, 2 to 2_253_000, 2 to 2_802_000),
            ),
        )
        // Helio G85-style 2 + 6: the clocks are too close to tell apart, so
        // every core counts and the old ceiling decides.
        assertEquals(
            8,
            WhisperCpuConfig.performanceCoreCount(cores(6 to 1_800_000, 2 to 2_000_000)),
        )
    }

    @Test
    fun `a phone that does not publish every clock is not guessed at`() {
        assertEquals(null, WhisperCpuConfig.performanceCoreCount(emptyList()))
        assertEquals(
            null,
            WhisperCpuConfig.performanceCoreCount(listOf(1_766_400, 0, 2_803_200, 2_803_200)),
        )
    }

    @Test
    fun `whisper workers stay on the performance cores`() {
        // 4 + 4: four big-core workers instead of two of them dragging two
        // efficiency cores through every barrier.
        assertEquals(4, WhisperCpuConfig.whisperThreadCount(8, "base-q8_0", performanceCores = 4))
        // 2 + 6 reads as eight even cores: exactly the old count.
        assertEquals(6, WhisperCpuConfig.whisperThreadCount(8, "base-q8_0", performanceCores = 8))
        // Two big cores still get the floor of two workers.
        assertEquals(2, WhisperCpuConfig.whisperThreadCount(8, "base-q8_0", performanceCores = 2))
        // Never more than "all but two", which leaves the phone its UI.
        assertEquals(2, WhisperCpuConfig.whisperThreadCount(4, "base-q8_0", performanceCores = 4))
        // The large-model ceiling still applies.
        assertEquals(
            4,
            WhisperCpuConfig.whisperThreadCount(12, "large-v3-turbo-q8_0", performanceCores = 8),
        )
        // Unreadable sysfs: the old formula.
        assertEquals(6, WhisperCpuConfig.whisperThreadCount(8, "base-q8_0", performanceCores = null))
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
        assertFalse(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("parakeet-tdt-ctc-110m-en")!!))
        assertFalse(LocalModelCatalog.isSlowOnMobile(LocalModelCatalog.find("parakeet-tdt-0.6b-v3")!!))
    }
}
