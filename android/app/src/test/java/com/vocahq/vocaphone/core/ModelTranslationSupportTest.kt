package com.vocahq.vocaphone.core

import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelTranslationSupportTest {

    private val canary = setOf("en", "de", "es", "fr")
    private val whisper = setOf("en")

    /**
     * The capability matrix is the whole feature. Getting it wrong in the
     * permissive direction is what produced the belief that any model can be
     * asked for any output language.
     */
    @Test
    fun `only the two models that can translate claim to`() {
        fun targets(id: String) =
            requireNotNull(LocalModelCatalog.find(id)) { "missing $id" }.translationTargets

        // Canary is a speech-translation model across the languages it lists.
        assertEquals(canary, targets("canary-180m-flash"))
        // Whisper's translate task has exactly one trained target.
        assertEquals(whisper, targets("small-q5_1"))
        assertEquals(whisper, targets("large-v3"))
        // An English-only whisper build has nothing to translate from.
        assertTrue(targets("small.en").isEmpty())
        // The transducers and CTC models transcribe and nothing else. Parakeet
        // v3 is the one people expect to translate because it is multilingual.
        assertTrue(targets("parakeet-tdt-0.6b-v3").isEmpty())
        assertTrue(targets("parakeet-tdt-0.6b-v2-en").isEmpty())
        assertTrue(targets("dolphin-small-ctc").isEmpty())
        assertTrue(targets("sense-voice").isEmpty())
        assertTrue(targets("moonshine-base-en").isEmpty())
        assertTrue(targets("fast-conformer-ctc-4-lang").isEmpty())
    }

    @Test
    fun `off is always selectable and a target is only selectable where trained`() {
        assertTrue(ModelTranslationSupport.isSelectable(ModelTranslationSupport.OFF, emptySet()))
        assertTrue(ModelTranslationSupport.isSelectable(TranscriptionLanguage.GERMAN, canary))
        assertFalse(ModelTranslationSupport.isSelectable(TranscriptionLanguage.HINDI, canary))
        // Whisper into English, and nothing else. Russian here is the exact
        // request that used to appear to work.
        assertTrue(ModelTranslationSupport.isSelectable(TranscriptionLanguage.ENGLISH, whisper))
        assertFalse(ModelTranslationSupport.isSelectable(TranscriptionLanguage.RUSSIAN, whisper))
    }

    /**
     * A target picked under Canary and left stored while the user switches to
     * Parakeet must not survive as a request no engine can honour.
     */
    @Test
    fun `a stale target falls back to no translation`() {
        assertEquals(
            ModelTranslationSupport.OFF,
            ModelTranslationSupport.resolve(TranscriptionLanguage.GERMAN, emptySet()),
        )
        assertEquals(
            TranscriptionLanguage.GERMAN,
            ModelTranslationSupport.resolve(TranscriptionLanguage.GERMAN, canary),
        )
    }

    /** "auto" is a language to the engines, so absence has to reach them empty. */
    @Test
    fun `the engine target is a code or nothing at all`() {
        assertEquals("de", ModelTranslationSupport.target(TranscriptionLanguage.GERMAN, canary))
        assertEquals("", ModelTranslationSupport.target(ModelTranslationSupport.OFF, canary))
        assertEquals("", ModelTranslationSupport.target(TranscriptionLanguage.GERMAN, emptySet()))
    }

    @Test
    fun `the row says which of the three states it is in`() {
        assertEquals(
            "Not supported by this model",
            ModelTranslationSupport.summary(TranscriptionLanguage.GERMAN, emptySet()),
        )
        assertEquals("Off", ModelTranslationSupport.summary(ModelTranslationSupport.OFF, canary))
        assertEquals("German", ModelTranslationSupport.summary(TranscriptionLanguage.GERMAN, canary))
        // Stored but unhonourable reads as Off, because Off is what happens.
        assertEquals("Off", ModelTranslationSupport.summary(TranscriptionLanguage.HINDI, canary))
        // A gateway has no local model to blame, and the fix is another screen.
        assertEquals(
            "Needs an on-device model",
            ModelTranslationSupport.summary(
                TranscriptionLanguage.GERMAN,
                emptySet(),
                onDevice = false,
            ),
        )
    }

    @Test
    fun `an unsupported model explains that the language row never translated`() {
        val none = ModelTranslationSupport.restriction(emptySet(), onDevice = true)!!
        assertTrue(none.contains("cannot translate"))
        assertTrue(none.contains("never translated speech"))

        val supported = ModelTranslationSupport.restriction(canary, onDevice = true)!!
        assertTrue(supported.contains("English, French, German and Spanish"))

        // Translation is an on-device feature; the gateway protocol has no
        // field for it, so saying so beats greying rows with no reason.
        assertTrue(
            ModelTranslationSupport.restriction(canary, onDevice = false)!!
                .contains("runs on this phone only"),
        )
    }

    /**
     * The one way this setting can be wrong without looking wrong. Canary is
     * told what it is translating from, so Automatic resolves to English and a
     * German speaker is translated out of a language they never spoke.
     */
    @Test
    fun `a model that cannot detect the source says so while the source is automatic`() {
        val warned = ModelTranslationSupport.restriction(
            canary,
            onDevice = true,
            needsExplicitSource = true,
            sourceIsAutomatic = true,
        )!!
        assertTrue(warned.contains("cannot work out what you are speaking"))
        assertTrue(warned.contains("as though you had spoken English"))

        // An explicit spoken language is the fix, so there is nothing to warn about.
        assertFalse(
            ModelTranslationSupport.restriction(
                canary,
                onDevice = true,
                needsExplicitSource = true,
                sourceIsAutomatic = false,
            )!!.contains("cannot work out"),
        )
        // Whisper detects the language and then translates, so Automatic is fine.
        assertFalse(
            ModelTranslationSupport.restriction(
                whisper,
                onDevice = true,
                needsExplicitSource = false,
                sourceIsAutomatic = true,
            )!!.contains("cannot work out"),
        )
    }

    /** Only Canary is told its source language; nothing else needs one. */
    @Test
    fun `only canary needs the spoken language named`() {
        fun needsSource(id: String) =
            requireNotNull(LocalModelCatalog.find(id)).translationNeedsExplicitSource
        assertTrue(needsSource("canary-180m-flash"))
        assertFalse(needsSource("small-q5_1"))
        assertFalse(needsSource("parakeet-tdt-0.6b-v3"))
    }

    /**
     * Settings is where the two halves meet: a target is only real while the
     * selected model is local and can honour it.
     */
    @Test
    fun `settings only offers a target the active model can honour`() {
        val onCanary = VocaPhoneSettings(
            translateTo = TranscriptionLanguage.GERMAN,
            localTranscriptionEnabled = true,
            localModelId = "canary-180m-flash",
        )
        assertEquals(canary, onCanary.activeModelTranslationTargets)
        assertEquals(TranscriptionLanguage.GERMAN, onCanary.effectiveTranslateTo)
        assertEquals("de", onCanary.translationTarget)

        // Same stored choice, a model that cannot translate.
        val onParakeet = onCanary.copy(localModelId = "parakeet-tdt-0.6b-v3")
        assertTrue(onParakeet.activeModelTranslationTargets.isEmpty())
        assertEquals(ModelTranslationSupport.OFF, onParakeet.effectiveTranslateTo)
        assertEquals("", onParakeet.translationTarget)
        // The preference itself survives for when a capable model returns.
        assertEquals(TranscriptionLanguage.GERMAN, onParakeet.translateTo)

        // A gateway has no translation field at all.
        assertEquals("", onCanary.copy(localTranscriptionEnabled = false).translationTarget)
    }
}
