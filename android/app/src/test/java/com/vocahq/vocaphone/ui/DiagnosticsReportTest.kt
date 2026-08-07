package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.settings.VocaPhoneSettings
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
    )

    private val ready = SetupStatus(
        microphone = true,
        notifications = true,
        overlay = true,
        accessibility = true,
        gatewayConfigured = true,
        disclosureAccepted = true,
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
        assertTrue(report.contains("Engine: unknown (not ready)"))
        assertTrue(report.contains("Streaming: batch upload"))
        assertTrue(report.contains("Setup: missing"))
        assertTrue(report.contains(SetupStep.MICROPHONE.label))
    }
}
