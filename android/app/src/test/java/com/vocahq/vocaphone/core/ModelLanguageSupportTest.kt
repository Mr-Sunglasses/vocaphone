package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelLanguageSupportTest {

    private val dolphin = setOf("hi", "bn", "ta", "zh", "ja")
    private val englishOnly = setOf("en")

    @Test
    fun `an explicit language remains the transcript output contract`() {
        assertEquals("hi", ModelLanguageSupport.transcriptLanguage("hi", "en"))
        assertEquals("en", ModelLanguageSupport.transcriptLanguage("en", "hi"))
        assertEquals("hi", ModelLanguageSupport.transcriptLanguage("auto", "hi"))
        assertEquals("", ModelLanguageSupport.transcriptLanguage("auto", ""))
    }

    /**
     * Coverage is the only test. An auto-detecting model still knows exactly
     * which languages it was trained on, and hiding them made a 25-language
     * Parakeet look like it spoke none of them.
     */
    @Test
    fun `a model offers exactly what it covers, detected or not`() {
        assertTrue(ModelLanguageSupport.isSelectable(TranscriptionLanguage.AUTOMATIC, dolphin))
        assertTrue(ModelLanguageSupport.isSelectable(TranscriptionLanguage.HINDI, dolphin))
        assertTrue(ModelLanguageSupport.isSelectable(TranscriptionLanguage.TAMIL, dolphin))
        assertFalse(ModelLanguageSupport.isSelectable(TranscriptionLanguage.FRENCH, dolphin))
        assertTrue(ModelLanguageSupport.isSelectable(TranscriptionLanguage.ENGLISH, englishOnly))
        assertFalse(ModelLanguageSupport.isSelectable(TranscriptionLanguage.HINDI, englishOnly))
    }

    @Test
    fun `an unknown gateway never locks the picker`() {
        // Older gateway, no model selected, or an imported one. Being uninformed
        // must not look like being unsupported.
        for (language in TranscriptionLanguage.entries) {
            assertTrue(
                "$language must stay selectable when the gateway made no claim",
                ModelLanguageSupport.isSelectable(language, emptySet()),
            )
        }
    }

    @Test
    fun `a stale selection falls back to Automatic instead of failing`() {
        // The user picked Hindi, then switched the gateway to an English-only
        // model. Sending "hi" anyway is exactly the failure this prevents.
        assertEquals(
            TranscriptionLanguage.AUTOMATIC,
            ModelLanguageSupport.resolve(TranscriptionLanguage.HINDI, englishOnly),
        )
        // A selection the model covers is left alone.
        assertEquals(
            TranscriptionLanguage.HINDI,
            ModelLanguageSupport.resolve(TranscriptionLanguage.HINDI, dolphin),
        )
        assertEquals(
            TranscriptionLanguage.HINDI,
            ModelLanguageSupport.resolve(TranscriptionLanguage.HINDI, emptySet()),
        )
    }

    @Test
    fun `the restriction is explained only when there is one`() {
        assertNull(ModelLanguageSupport.restriction(emptySet(), false))
        val limited = ModelLanguageSupport.restriction(dolphin, false)
        assertTrue(limited!!.contains("${dolphin.size} languages"))
        val oneLanguage = ModelLanguageSupport.restriction(setOf("en"), false)
        assertTrue(oneLanguage!!.contains("1 language."))
    }

    /**
     * The sentence has to say both things: the choice is real for punctuation,
     * and it is not a decoder setting. Promising either half alone is how the
     * picker starts lying about what the model does.
     */
    @Test
    fun `an auto-detecting model says what picking a language does`() {
        val detected = ModelLanguageSupport.restriction(dolphin, true)!!
        assertTrue(detected.contains("${dolphin.size} languages"))
        assertTrue(detected.contains("does not pin the decoder"))
        assertTrue(detected.contains("punctuated"))
        // With no coverage claim there is still the detection half to explain.
        val unclaimed = ModelLanguageSupport.restriction(emptySet(), true)!!
        assertTrue(unclaimed.contains("does not pin the decoder"))
        assertTrue(
            ModelLanguageSupport.restriction(dolphin, true, onDevice = true)!!
                .contains("The on-device model"),
        )
    }

    /// What Settings shows must be what dictation does. The stored choice is
    /// kept, but a row reading "Hindi" while Automatic is what actually happens
    /// is the interface lying about the result.
    @Test
    fun `the displayed language is the one that will be used`() {
        val settings = com.vocahq.vocaphone.settings.VocaPhoneSettings(
            language = TranscriptionLanguage.HINDI,
            modelLanguages = englishOnly,
            modelDetectsLanguage = false,
        )
        assertEquals(TranscriptionLanguage.AUTOMATIC, settings.effectiveLanguage)
        // The stored preference survives and returns once a model supports it.
        assertEquals(TranscriptionLanguage.HINDI, settings.language)
        assertEquals(
            TranscriptionLanguage.HINDI,
            settings.copy(modelLanguages = setOf("en", "hi")).effectiveLanguage,
        )
    }
}
