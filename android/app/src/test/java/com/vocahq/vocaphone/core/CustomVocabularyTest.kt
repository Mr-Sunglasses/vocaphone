package com.vocahq.vocaphone.core

import com.vocahq.vocaphone.settings.VocaPhoneSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CustomVocabularyTest {

    @Test
    fun `terms split on newlines and commas but never inside a phrase`() {
        assertEquals(
            listOf("Claude Code", "Tailscale", "VocaPhone"),
            CustomVocabulary.terms("Claude Code\nTailscale, VocaPhone"),
        )
    }

    @Test
    fun `the first spelling of a duplicate is the one kept`() {
        assertEquals(
            listOf("VocaPhone"),
            CustomVocabulary.terms("VocaPhone, vocaphone, VOCAPHONE"),
        )
    }

    @Test
    fun `blank entries and stray separators are dropped`() {
        assertEquals(emptyList<String>(), CustomVocabulary.terms(null))
        assertEquals(emptyList<String>(), CustomVocabulary.terms("  \n , , \n "))
        assertEquals(listOf("Kanishk"), CustomVocabulary.terms(",\n Kanishk ,\n"))
    }

    @Test
    fun `the prompt is a comma separated list the decoder can read as text`() {
        assertEquals(
            "Kanishk, VocaHQ, Tailscale.",
            CustomVocabulary.whisperPrompt("Kanishk\nVocaHQ\nTailscale"),
        )
        assertEquals("", CustomVocabulary.whisperPrompt(""))
    }

    @Test
    fun `an over-long list is truncated at a term boundary`() {
        val prompt = CustomVocabulary.whisperPrompt(
            (1..200).joinToString("\n") { "Supercalifragilistic$it" },
        )
        assertTrue("prompt should be bounded", prompt.length <= 641)
        // Never a half-written term: every entry present is complete.
        prompt.removeSuffix(".").split(", ").forEach { term ->
            assertTrue("`$term` should be whole", term.matches(Regex("Supercalifragilistic\\d+")))
        }
    }

    @Test
    fun `a non-whisper model gets a clear warning`() {
        val note = CustomVocabulary.whisperOnlyWarning("Parakeet")
        assertEquals("Parakeet is not Whisper. Custom words only apply to Whisper models.", note)
        assertEquals(
            "Parakeet TDT 0.6B is not Whisper. Custom words only apply to Whisper models.",
            CustomVocabulary.whisperOnlyWarning("Parakeet TDT 0.6B"),
        )
        assertEquals(null, CustomVocabulary.whisperOnlyWarning(null))
        assertEquals(null, CustomVocabulary.whisperOnlyWarning(""))
    }

    @Test
    fun `whisper uses the personal dictionary until the user unlinks them`() {
        val personal = "Grafana, Kubernetes"
        val custom = "Kanishk\nVocaHQ"
        assertEquals(
            personal,
            VocaPhoneSettings(
                personalDictionary = personal,
                customVocabulary = custom,
                syncWhisperDictionary = true,
            ).whisperVocabulary,
        )
        assertEquals(
            custom,
            VocaPhoneSettings(
                personalDictionary = personal,
                customVocabulary = custom,
                syncWhisperDictionary = false,
            ).whisperVocabulary,
        )
        assertTrue(VocaPhoneSettings().syncWhisperDictionary)
    }
}
