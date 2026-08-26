package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        //
        // Output-script rows are the one exception, and they are excluded here
        // rather than weakening the rule. "Almost every model transcribes Hindi"
        // is what makes silence a yes; nothing about that reasoning carries over
        // to Roman Hinglish, which one model in the catalog produces and every
        // other model would answer with Devanagari. See
        // `HinglishModelTest.the roman row needs a model that says so`.
        for (language in TranscriptionLanguage.entries.filterNot { it.isOutputScript }) {
            assertTrue(
                "$language must stay selectable when the gateway made no claim",
                ModelLanguageSupport.isSelectable(language, emptySet()),
            )
        }
    }

    @Test
    fun `an output script is offered only where it is claimed outright`() {
        val roman = TranscriptionLanguage.HINGLISH_ROMAN
        assertFalse(ModelLanguageSupport.isSelectable(roman, emptySet()))
        assertFalse(ModelLanguageSupport.isSelectable(roman, dolphin))
        assertTrue(ModelLanguageSupport.isSelectable(roman, setOf(roman.wireValue)))
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
    fun `a coverage limit is spelled out whenever there is one`() {
        val limited = ModelLanguageSupport.restriction(dolphin, false, canTranslate = false)
        assertTrue(limited!!.contains("${dolphin.size} languages"))
        val oneLanguage = ModelLanguageSupport.restriction(setOf("en"), false, canTranslate = false)
        assertTrue(oneLanguage!!.contains("1 language."))
        // No coverage claim leaves nothing to say about coverage.
        assertFalse(
            ModelLanguageSupport.restriction(emptySet(), false, canTranslate = false)!!.contains("covers"),
        )
    }

    /**
     * The picker used to say nothing at all for an unrestricted model, which is
     * exactly the case — a multilingual Whisper — where someone picks Russian,
     * speaks English, and concludes the app translates. It never did: Whisper
     * forces the language token and renders the meaning it heard in that
     * script, untrained and unreliable.
     */
    @Test
    fun `every model says the language row is not a translation setting`() {
        for (detects in listOf(false, true)) {
            val sentence = ModelLanguageSupport.restriction(emptySet(), detects, canTranslate = false)!!
            assertTrue(sentence.contains("not the language you want back"))
            assertTrue(sentence.contains("cannot translate"))
        }
        // A model that can translate points at the row that does it instead of
        // repeating the warning.
        val canary = ModelLanguageSupport.restriction(
            setOf("en", "de", "es", "fr"),
            false,
            canTranslate = true,
            onDevice = true,
        )!!
        assertTrue(canary.contains("use Translate to"))
        assertFalse(canary.contains("cannot translate"))
    }

    /**
     * With translation on, two languages are in play and only one of them is
     * the one on screen. The styler punctuates by script, so it has to be given
     * the target.
     */
    @Test
    fun `the output language is the translation target when translating`() {
        assertEquals("de", ModelLanguageSupport.outputLanguage("hi", "hi", "de"))
        assertEquals("de", ModelLanguageSupport.outputLanguage("auto", "hi", "de"))
        // Empty is no translation, which leaves the old contract untouched.
        assertEquals("hi", ModelLanguageSupport.outputLanguage("hi", "en", ""))
        assertEquals("hi", ModelLanguageSupport.outputLanguage("auto", "hi", ""))
    }

    /**
     * The sentence has to say both things: the choice is real for punctuation,
     * and it is not a decoder setting. Promising either half alone is how the
     * picker starts lying about what the model does.
     */
    @Test
    fun `an auto-detecting model says what picking a language does`() {
        val detected = ModelLanguageSupport.restriction(dolphin, true, canTranslate = false)!!
        assertTrue(detected.contains("${dolphin.size} languages"))
        assertTrue(detected.contains("does not pin the decoder"))
        assertTrue(detected.contains("punctuated"))
        // With no coverage claim there is still the detection half to explain.
        val unclaimed = ModelLanguageSupport.restriction(emptySet(), true, canTranslate = false)!!
        assertTrue(unclaimed.contains("does not pin the decoder"))
        assertTrue(
            ModelLanguageSupport.restriction(dolphin, true, canTranslate = false, onDevice = true)!!
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
