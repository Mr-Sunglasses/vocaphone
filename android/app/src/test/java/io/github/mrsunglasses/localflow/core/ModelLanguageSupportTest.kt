package io.github.mrsunglasses.localflow.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelLanguageSupportTest {

    private val dolphin = setOf("hi", "bn", "ta", "zh", "ja")
    private val englishOnly = setOf("en")

    @Test
    fun `a model that detects its own language offers only Automatic`() {
        // Dolphin ignores the requested language, so offering Hindi promises
        // something it cannot deliver — it returned Cyrillic for a short Hindi clip.
        assertTrue(
            ModelLanguageSupport.isSelectable(TranscriptionLanguage.AUTOMATIC, dolphin, true),
        )
        for (language in TranscriptionLanguage.entries - TranscriptionLanguage.AUTOMATIC) {
            assertFalse(
                "$language should not be selectable on an auto-detecting model",
                ModelLanguageSupport.isSelectable(language, dolphin, true),
            )
        }
    }

    @Test
    fun `a pinnable model offers exactly what it covers`() {
        assertTrue(ModelLanguageSupport.isSelectable(TranscriptionLanguage.HINDI, dolphin, false))
        assertTrue(ModelLanguageSupport.isSelectable(TranscriptionLanguage.TAMIL, dolphin, false))
        assertFalse(ModelLanguageSupport.isSelectable(TranscriptionLanguage.FRENCH, dolphin, false))
        assertTrue(ModelLanguageSupport.isSelectable(TranscriptionLanguage.ENGLISH, englishOnly, false))
        assertFalse(ModelLanguageSupport.isSelectable(TranscriptionLanguage.HINDI, englishOnly, false))
    }

    @Test
    fun `an unknown gateway never locks the picker`() {
        // Older gateway, no model selected, or an imported one. Being uninformed
        // must not look like being unsupported.
        for (language in TranscriptionLanguage.entries) {
            assertTrue(
                "$language must stay selectable when the gateway made no claim",
                ModelLanguageSupport.isSelectable(language, emptySet(), false),
            )
        }
    }

    @Test
    fun `a stale selection falls back to Automatic instead of failing`() {
        // The user picked Hindi, then switched the gateway to an English-only
        // model. Sending "hi" anyway is exactly the failure this prevents.
        assertEquals(
            TranscriptionLanguage.AUTOMATIC,
            ModelLanguageSupport.resolve(TranscriptionLanguage.HINDI, englishOnly, false),
        )
        assertEquals(
            TranscriptionLanguage.AUTOMATIC,
            ModelLanguageSupport.resolve(TranscriptionLanguage.HINDI, dolphin, true),
        )
        // A selection the model can honour is left alone.
        assertEquals(
            TranscriptionLanguage.HINDI,
            ModelLanguageSupport.resolve(TranscriptionLanguage.HINDI, dolphin, false),
        )
        assertEquals(
            TranscriptionLanguage.HINDI,
            ModelLanguageSupport.resolve(TranscriptionLanguage.HINDI, emptySet(), false),
        )
    }

    @Test
    fun `the restriction is explained only when there is one`() {
        assertNull(ModelLanguageSupport.restriction(emptySet(), false))
        val automatic = ModelLanguageSupport.restriction(dolphin, true)
        assertTrue(automatic!!.contains("detects the language itself"))
        val limited = ModelLanguageSupport.restriction(dolphin, false)
        assertTrue(limited!!.contains("${dolphin.size} languages"))
    }
}
