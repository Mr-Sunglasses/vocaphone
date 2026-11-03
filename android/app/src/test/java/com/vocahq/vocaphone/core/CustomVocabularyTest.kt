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
    fun `a non-whisper model is told what the list still does`() {
        val note = CustomVocabulary.spellingOnlyNote("Parakeet")
        assertEquals(
            "Parakeet cannot be nudged while it decodes, so only close matches are " +
                "corrected. A word it hears as something else entirely stays as it heard it.",
            note,
        )
        assertEquals(null, CustomVocabulary.spellingOnlyNote(null))
        assertEquals(null, CustomVocabulary.spellingOnlyNote(""))
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
