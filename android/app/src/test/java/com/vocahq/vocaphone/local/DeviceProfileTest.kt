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
        language: String = "en",
    ) = DeviceProfile(ram, cores, mpc, abi, khz, sherpa, language)

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
        assertEquals(3, profile(4).modelRamBudgetGB)
        assertEquals(7, profile(8).modelRamBudgetGB)
        assertEquals(14, profile(16).modelRamBudgetGB)
        assertEquals(18, profile(20).modelRamBudgetGB)
    }

    @Test
    fun `english default is a small moonshine, not a 670 MB parakeet`() {
        for (ram in listOf(4L, 8L, 16L, 20L)) {
            val pick = LocalModelCatalog.recommended(profile(ram, language = "en"))
            assertEquals("moonshine-tiny-en", pick.id)
            assertTrue(pick.sizeBytes < 200_000_000L)
            assertTrue(pick.minimumRamGB <= profile(ram).modelRamBudgetGB)
        }
        val parakeet = LocalModelCatalog.find("parakeet-tdt-0.6b-v3")!!
        assertTrue(LocalModelCatalog.isUsableOnDevice(parakeet, 8, sherpaAvailable = true))
    }

    @Test
    fun `the default follows the phone language`() {
        assertEquals(
            "canary-180m-flash",
            LocalModelCatalog.recommended(profile(8, language = "de")).id,
        )
        assertEquals(
            "canary-180m-flash",
            LocalModelCatalog.recommended(profile(8, language = "es")).id,
        )
        assertEquals(
            "canary-180m-flash",
            LocalModelCatalog.recommended(profile(8, language = "fr")).id,
        )
        assertEquals(
            "paraformer-zh-small",
            LocalModelCatalog.recommended(profile(8, language = "zh")).id,
        )
        assertEquals(
            "sense-voice",
            LocalModelCatalog.recommended(profile(8, language = "ja")).id,
        )
        assertEquals(
            "sense-voice",
            LocalModelCatalog.recommended(profile(8, language = "ko")).id,
        )
        assertEquals(
            "giga-am-ctc-ru",
            LocalModelCatalog.recommended(profile(8, language = "ru")).id,
        )
        assertEquals(
            "dolphin-base-ctc",
            LocalModelCatalog.recommended(profile(8, language = "hi")).id,
        )
        val italian = LocalModelCatalog.recommended(profile(8, language = "it"))
        assertEquals(LocalModelEngine.WHISPER, italian.engine)
        assertTrue(italian.sizeBytes < 200_000_000L)
        assertTrue(italian.coversLanguage("it"))
    }

    @Test
    fun `four GB sherpa phone keeps a memory margin for the default`() {
        val pick = LocalModelCatalog.recommended(profile(4))
        assertEquals(SherpaFamily.MOONSHINE, pick.sherpaFamily)
        assertTrue(pick.minimumRamGB <= profile(4).modelRamBudgetGB)
        // Parakeet remains an explicit catalog choice when the user accepts
        // the memory tradeoff; this test covers only the automatic default.
        val parakeet = LocalModelCatalog.find("parakeet-tdt-0.6b-v3")!!
        assertTrue(LocalModelCatalog.isUsableOnDevice(parakeet, 4, sherpaAvailable = true))
    }

    @Test
    fun `without sherpa the class picks a matching whisper, not the largest file`() {
        assertEquals(
            "tiny-q5_1",
            LocalModelCatalog.recommended(profile(2, sherpa = false)).id,
        )
        assertEquals(
            "base-q5_1",
            LocalModelCatalog.recommended(profile(4, sherpa = false)).id,
        )
        assertEquals(
            "base-q5_1",
            LocalModelCatalog.recommended(profile(8, mpc = 0, sherpa = false)).id,
        )
        // Large v3 / turbo stays in the catalog with a slow-on-phone mark.
        // First-run must not start a 1.6 GB download even on a flagship.
        val flagship = LocalModelCatalog.recommended(profile(12, mpc = 34, sherpa = false))
        assertEquals(LocalModelEngine.WHISPER, flagship.engine)
        assertTrue(flagship.sizeBytes < 600_000_000L)
        assertTrue(!flagship.id.contains("large"))
        assertEquals(
            "small-q5_1",
            LocalModelCatalog.recommended(profile(16, sherpa = false)).id,
        )
    }

    @Test
    fun `poco class hardware stays on base whisper without a sherpa runtime`() {
        val pocoF1 = profile(
            ram = 6,
            cores = 8,
            mpc = 0,
            khz = 2_800_000,
            sherpa = false,
        )
        assertEquals(DeviceTier.FAST, pocoF1.tier)
        assertEquals("base-q5_1", LocalModelCatalog.recommendedWhisper(pocoF1).id)
        assertEquals("base-q5_1", LocalModelCatalog.recommended(pocoF1).id)
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
