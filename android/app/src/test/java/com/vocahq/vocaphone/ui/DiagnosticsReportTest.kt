package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.settings.VocaPhoneSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticsReportTest {

    private val info = AppInfo(
        versionName = "0.1.0-beta.3",
        versionCode = 3,
        packageName = "com.vocahq.vocaphone",
        installedFrom = "sideloaded",
        androidRelease = "14",
        sdkInt = 34,
        device = "Google Pixel 6a",
    )

    private val configured = VocaPhoneSettings(
        gatewayUrl = "http://homelabone.local:8765",
        hasToken = true,
        lastEngine = "moonshine:en",
        lastEngineReady = true,
        lastStreamingSupported = true,
        localTranscriptionEnabled = false,
    )

    private val ready = SetupStatus(
        microphone = true,
        notifications = true,
        keyboard = true,
        gatewayConfigured = true,
    )

    @Test
    fun `report carries the version, platform and engine`() {
        val report = diagnosticsReport(info, configured, ready)

        assertTrue(report.contains("VocaPhone 0.1.0-beta.3 (3)"))
        assertTrue(report.contains("Android 14 (SDK 34)"))
        assertTrue(report.contains("Google Pixel 6a"))
        assertTrue(report.contains("sideloaded"))
        assertTrue(report.contains("moonshine:en (ready)"))
        assertTrue(report.contains("Streaming: supported"))
        assertTrue(report.contains("Setup: all steps done"))
    }

    @Test
    fun `the gateway host name never reaches the report`() {
        val report = diagnosticsReport(info, configured, ready)

        assertFalse(report.contains("homelabone"))
        assertFalse(report.contains("8765"))
        assertTrue(report.contains("http:// (private host)"))
    }

    @Test
    fun `an https gateway is reported as encrypted`() {
        val settings = configured.copy(gatewayUrl = "https://voice.example.com")

        val report = diagnosticsReport(info, settings, ready)

        assertFalse(report.contains("example.com"))
        assertTrue(report.contains("Gateway: https://"))
    }

    @Test
    fun `an unconfigured install names the steps still outstanding`() {
        val report = diagnosticsReport(info, VocaPhoneSettings(), SetupStatus())

        assertTrue(report.contains("Gateway: not configured"))
        assertTrue(report.contains("Speech: On this phone"))
        assertTrue(report.contains("Local model: none"))
        assertTrue(report.contains("Setup: missing"))
        assertTrue(report.contains(SetupStep.MICROPHONE.label))
        assertFalse(report.contains("Engine: unknown (not ready)"))
    }

    @Test
    fun `report can include the bounded operational event log`() {
        val report = diagnosticsReport(
            info,
            configured,
            ready,
            events = "ts=1 build=0.1.0 event=state value=LISTENING source=IME\n",
        )

        assertTrue(report.contains("Event log:"))
        assertTrue(report.contains("value=LISTENING source=IME"))
    }

    @Test
    fun `local speech names the phone instead of a stale gateway engine`() {
        val settings = configured.copy(
            localTranscriptionEnabled = true,
            localModelId = "tiny-q8_0",
        )

        val report = diagnosticsReport(info, settings, ready)

        assertTrue(report.contains("Speech: On this phone · Whisper Tiny"))
        assertTrue(report.contains("Local model: tiny-q8_0"))
        assertTrue(report.contains("Quality: Balanced"))
        assertFalse(report.contains("Engine: moonshine:en"))
        assertFalse(report.contains("homelabone"))
    }

    @Test
    fun `on-device hardware lands in the report without file paths`() {
        val onDevice = OnDeviceDiagnostics(
            totalRamBytes = 8_000_000_000L,
            availRamBytes = 1_200_000_000L,
            totalStorageBytes = 128_000_000_000L,
            availStorageBytes = 12_000_000_000L,
            modelStorageBytes = 340_000_000L,
            downloadedModelIds = listOf("base-q8_0", "tiny-q8_0"),
            cpuCores = 8,
            abi = "arm64-v8a",
            soc = "Google Tensor",
            cpuFeatures = listOf("asimdhp", "asimddp"),
            performanceClass = 34,
        )

        val report = diagnosticsReport(
            info,
            configured.copy(localTranscriptionEnabled = true, localModelId = "tiny-q8_0"),
            ready,
            onDevice = onDevice,
        )

        assertTrue(report.contains("Downloaded models: base-q8_0, tiny-q8_0 (2)"))
        assertTrue(report.contains("Model storage: 340 MB"))
        assertTrue(report.contains("RAM: 8.0 GB total, 1.2 GB available"))
        assertTrue(report.contains("Storage: 12.0 GB free of 128.0 GB"))
        assertTrue(report.contains("CPU: 8 cores · arm64-v8a · Google Tensor"))
        assertTrue(report.contains("CPU features: asimdhp, asimddp"))
        assertTrue(report.contains("Performance class: 34"))
        assertFalse(report.contains("local-models"))
        assertFalse(report.contains("/data/"))
    }

    /** A Snapdragon 8 Elite Gen 5, which is the shape this line exists for. */
    private val sm8850Cpuinfo = """
        processor	: 0
        BogoMIPS	: 38.40
        Features	: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm jscvt fcma lrcpc dcpop sha3 sm3 sm4 asimddp sha512 asimdfhm dit uscat ilrcpc flagm ssbs sb paca pacg dcpodp flagm2 frint i8mm bf16 dgh rng bti ecv afp wfxt sme smei8i32 smef16f32 smeb16f32 smef32f32
        CPU implementer	: 0x51
        processor	: 1
        Features	: fp asimd evtstrm aes pmull asimddp i8mm bf16 sme
        Hardware	: Qualcomm Technologies, Inc SM8850
    """.trimIndent()

    @Test
    fun `sme without sme2 is visible in the features`() {
        val features = cpuFeatures(sm8850Cpuinfo)

        assertTrue(features.contains("sme"))
        assertFalse(features.contains("sme2"))
        assertEquals(listOf("asimdhp", "asimddp", "i8mm", "bf16", "sme"), features)
    }

    @Test
    fun `a feature is matched whole, never as a prefix of a longer name`() {
        assertEquals(emptyList<String>(), cpuFeatures("Features\t: smei8i32 smef32f32 sve2fp16"))
        assertEquals(listOf("sve", "sve2"), cpuFeatures("Features\t: sve sve2 svei8mm"))
    }

    @Test
    fun `everything outside the allowlist is dropped rather than copied`() {
        val features = cpuFeatures(sm8850Cpuinfo)

        assertFalse(features.contains("aes"))
        assertFalse(features.contains("paca"))
        assertTrue(sm8850Cpuinfo.contains("Qualcomm Technologies"))
        assertFalse(features.any { it.contains("Qualcomm") })
    }

    @Test
    fun `a cpuinfo with no features of ours reports none, and drops the line`() {
        // 32-bit Arm, where none of what the engines dispatch on exists.
        val armv7 = "Features\t: swp half thumb fastmult vfp edsp neon vfpv3 tls idiva"

        assertEquals(emptyList<String>(), cpuFeatures(armv7))
        assertEquals(emptyList<String>(), cpuFeatures(""))
        assertFalse(
            onDeviceReportLines(OnDeviceDiagnostics(cpuCores = 8, abi = "armeabi-v7a"))
                .any { it.startsWith("CPU features:") },
        )
    }

    @Test
    fun `formatBytes uses GB then MB`() {
        assertTrue(formatBytes(8_000_000_000L).startsWith("8.0 GB"))
        assertTrue(formatBytes(340_000_000L) == "340 MB")
        assertTrue(formatBytes(900L) == "900 B")
    }

    @Test
    fun `directorySizeBytes sums files and ignores missing roots`() {
        val root = kotlin.io.path.createTempDirectory("voca-models").toFile()
        try {
            java.io.File(root, "tiny.bin").writeBytes(ByteArray(12))
            java.io.File(root, "nested").mkdirs()
            java.io.File(root, "nested/weights.bin").writeBytes(ByteArray(8))
            org.junit.Assert.assertEquals(20L, directorySizeBytes(root))
            org.junit.Assert.assertEquals(0L, directorySizeBytes(java.io.File(root, "missing")))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `privacy note keeps the real limits and skips em dashes`() {
        assertTrue(ABOUT_PRIVACY_NOTE.contains("32 characters"))
        assertTrue(ABOUT_PRIVACY_NOTE.contains("does not read the field"))
        assertTrue(ABOUT_PRIVACY_NOTE.contains("no cloud transcription"))
        assertFalse(ABOUT_PRIVACY_NOTE.contains("—"))
        assertFalse(ABOUT_PRIVACY_NOTE.contains("–"))
    }
}
