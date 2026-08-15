package com.vocahq.vocaphone.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class DeviceProfileTest {

    private fun profile(
        ram: Long,
        cores: Int = 8,
        mpc: Int = 0,
        abi: String = "arm64-v8a",
        khz: Int = 0,
        sherpa: Boolean = true,
    ) = DeviceProfile(ram, cores, mpc, abi, khz, sherpa)

    @Test
    fun `tiers follow ram, abi, clock and performance class`() {
        assertEquals(DeviceTier.CONSTRAINED, profile(3).tier)
        assertEquals(DeviceTier.CONSTRAINED, profile(8, abi = "armeabi-v7a").tier)
        assertEquals(DeviceTier.STANDARD, profile(4).tier)
        assertEquals(DeviceTier.FAST, profile(8).tier)
        assertEquals(DeviceTier.FAST, profile(6, mpc = 31).tier)
        assertEquals(DeviceTier.FAST, profile(6, cores = 8, khz = 2_800_000).tier)
        assertEquals(DeviceTier.FLAGSHIP, profile(16).tier)
        assertEquals(DeviceTier.FLAGSHIP, profile(12, mpc = 34).tier)
        assertEquals(DeviceTier.FLAGSHIP, profile(12, cores = 8, khz = 3_200_000).tier)
    }

    @Test
    fun `budget leaves headroom on fast and flagship phones`() {
        assertEquals(3, profile(3).modelRamBudgetGB)
        assertEquals(4, profile(4).modelRamBudgetGB)
        assertEquals(7, profile(8).modelRamBudgetGB)
        assertEquals(14, profile(16).modelRamBudgetGB)
        assertEquals(18, profile(20).modelRamBudgetGB)
    }

    @Test
    fun `sherpa phones pick the best fitting transducer, not a hardcoded id`() {
        for (ram in listOf(4L, 8L, 16L, 20L)) {
            val pick = LocalModelCatalog.recommended(profile(ram))
            assertEquals(SherpaFamily.NEMO_TRANSDUCER, pick.sherpaFamily)
            assertTrue(pick.minimumRamGB <= profile(ram).modelRamBudgetGB)
        }
        // Current catalog: multilingual Parakeet is the only transducer that
        // also covers more than English, so it wins the score on every tier
        // that can hold a 4 GB floor.
        assertEquals("parakeet-tdt-0.6b-v3", LocalModelCatalog.recommended(profile(8)).id)
    }

    @Test
    fun `without sherpa the class picks a matching whisper, not the largest file`() {
        assertEquals(
            "tiny-q5_1",
            LocalModelCatalog.recommended(profile(2, sherpa = false)).id,
        )
        assertEquals(
            "small-q5_1",
            LocalModelCatalog.recommended(profile(4, sherpa = false)).id,
        )
        assertEquals(
            "large-v3-turbo-q5_0",
            LocalModelCatalog.recommended(profile(8, mpc = 0, sherpa = false)).id,
        )
        assertEquals(
            "large-v3-turbo",
            LocalModelCatalog.recommended(profile(12, mpc = 34, sherpa = false)).id,
        )
        assertEquals(
            "large-v3",
            LocalModelCatalog.recommended(profile(16, sherpa = false)).id,
        )
    }

    @Test
    fun `constrained sherpa stays on a small family that fits the budget`() {
        val pick = LocalModelCatalog.recommended(profile(3))
        assertEquals(SherpaFamily.MOONSHINE, pick.sherpaFamily)
        assertTrue(pick.minimumRamGB <= 3)
    }

    @Test
    fun `32-bit stays inside the constrained budget`() {
        val pick = LocalModelCatalog.recommended(profile(8, abi = "armeabi-v7a"))
        assertTrue(pick.minimumRamGB <= 3)
        assertTrue(pick.engine == LocalModelEngine.WHISPER || pick.minimumRamGB <= 3)
    }

    @Test
    fun `sysfs max frequency uses the fastest core`() {
        val root = kotlin.io.path.createTempDirectory("cpu").toFile()
        try {
            File(root, "cpu0/cpufreq").mkdirs()
            File(root, "cpu1/cpufreq").mkdirs()
            File(root, "cpu0/cpufreq/cpuinfo_max_freq").writeText("1804800\n")
            File(root, "cpu1/cpufreq/cpuinfo_max_freq").writeText("2803200\n")
            assertEquals(2_803_200, readMaxCpuKHz(root))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `summary names the class and the budget`() {
        val text = profile(8, cores = 8, khz = 2_800_000).summary()
        assertTrue(text.contains("Fast class"))
        assertTrue(text.contains("8 GB RAM"))
        assertTrue(text.contains("8 cores"))
        assertTrue(text.contains("2.8 GHz"))
        assertTrue(text.contains("7 GB model budget"))
    }
}
