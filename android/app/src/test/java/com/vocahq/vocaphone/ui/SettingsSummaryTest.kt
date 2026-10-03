package com.vocahq.vocaphone.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsSummaryTest {

    @Test
    fun `counts read as words, not as zero`() {
        assertEquals("None yet", countLabel(0, "snippet"))
        assertEquals("1 snippet", countLabel(1, "snippet"))
        assertEquals("3 words", countLabel(3, "word"))
    }

    @Test
    fun `the keyboard row names one state`() {
        assertEquals("On", keyboardRowSummary(ImeSetupStatus(enabled = true, selected = true)))
        assertEquals("Turned on, not selected", keyboardRowSummary(ImeSetupStatus(enabled = true, selected = false)))
        assertEquals("Not turned on", keyboardRowSummary(ImeSetupStatus(enabled = false, selected = false)))
    }

    @Test
    fun `the gateway row shows the host and engine, never the scheme or path`() {
        assertEquals("Not set up", gatewayRowSummary(configured = false, url = "", lastEngine = ""))
        assertEquals(
            "gateway.example.com · faster-whisper:large-v3",
            gatewayRowSummary(
                configured = true,
                url = "https://gateway.example.com/v1/",
                lastEngine = "faster-whisper:large-v3",
            ),
        )
        assertEquals(
            "my-gateway.local:8765",
            gatewayRowSummary(configured = true, url = "http://my-gateway.local:8765", lastEngine = ""),
        )
    }

    @Test
    fun `settings pages open from their intent extras`() {
        assertEquals(SettingsPage.PRIVACY, SettingsPage.fromExtra("privacy"))
        assertEquals(SettingsPage.HELP, SettingsPage.fromExtra("HELP"))
        assertEquals(SettingsPage.DICTIONARY, SettingsPage.fromExtra("dictionary"))
        assertEquals(SettingsPage.HOME, SettingsPage.fromExtra(null))
    }

    @Test
    fun `editing the dictation list never shortens a long phrase`() {
        val long = "Ministry of Electronics and Information Technology of the Government of India"
        assertTrue(long.length > 64)
        assertEquals(listOf(long, "VocaHQ"), editableVocabulary("$long\nVocaHQ\nvocahq\n\n"))
        assertEquals(listOf("Claude Code", "Tailscale"), editableVocabulary("Claude Code, Tailscale"))
    }
}
