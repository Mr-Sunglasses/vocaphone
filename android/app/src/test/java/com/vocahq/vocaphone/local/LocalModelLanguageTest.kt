package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * On-device transcription must not inherit the gateway's language claim: the
 * gateway's last engine report says nothing about the model running on the phone.
 */
class LocalModelLanguageTest {
    private fun settings(
        language: TranscriptionLanguage,
        localModelId: String = "",
        localEnabled: Boolean = true,
        gatewayLanguages: Set<String> = emptySet(),
        gatewayDetects: Boolean = false,
    ) = VocaPhoneSettings(
        language = language,
        modelLanguages = gatewayLanguages,
        modelDetectsLanguage = gatewayDetects,
        localTranscriptionEnabled = localEnabled,
        localModelId = localModelId,
    )

    @Test
    fun aStaleGatewayClaimNoLongerNarrowsALocalMultilingualModel() {
        // The gateway last reported an English-only engine; the phone is running
        // a 100-language whisper build.
        val configured = settings(
            TranscriptionLanguage.HINDI,
            localModelId = "large-v3-turbo-q8_0",
            gatewayLanguages = setOf("en"),
        )
        assertEquals(TranscriptionLanguage.HINDI, configured.effectiveLanguage)
        assertTrue(configured.activeModelLanguages.isEmpty())
    }

    @Test
    fun aStaleGatewayAutoDetectClaimNoLongerForcesAutomatic() {
        val configured = settings(
            TranscriptionLanguage.GERMAN,
            localModelId = "large-v3-turbo-q8_0",
            gatewayDetects = true,
        )
        assertEquals(TranscriptionLanguage.GERMAN, configured.effectiveLanguage)
    }

    @Test
    fun anEnglishOnlyLocalModelStillRejectsOtherLanguages() {
        // Every whisper build in the catalog is multilingual now, so the
        // English-only case is a sherpa model.
        val configured = settings(TranscriptionLanguage.HINDI, localModelId = "moonshine-tiny-en")
        assertEquals(TranscriptionLanguage.AUTOMATIC, configured.effectiveLanguage)
        assertEquals(setOf("en"), configured.activeModelLanguages)
    }

    /**
     * SenseVoice takes a language on its sherpa config, so the pick is honoured
     * by the decoder itself rather than only by the punctuation pass.
     */
    @Test
    fun aPinnableLocalModelKeepsTheLanguageItCovers() {
        val configured = settings(TranscriptionLanguage.ENGLISH, localModelId = "sense-voice")
        assertEquals(TranscriptionLanguage.ENGLISH, configured.effectiveLanguage)
        assertFalse(configured.activeModelDetectsLanguage)
        assertEquals(
            TranscriptionLanguage.AUTOMATIC,
            settings(TranscriptionLanguage.HINDI, localModelId = "sense-voice").effectiveLanguage,
        )
    }

    /**
     * Parakeet v3 decides the language from the audio, but it still covers 25 of
     * them and the picker has to offer those: the choice is what the transcript
     * gets punctuated in, and before this it had none to work from.
     */
    @Test
    fun anAutoDetectingLocalModelStillOffersTheLanguagesItCovers() {
        val configured =
            settings(TranscriptionLanguage.RUSSIAN, localModelId = "parakeet-tdt-0.6b-v3")
        assertEquals(TranscriptionLanguage.RUSSIAN, configured.effectiveLanguage)
        assertTrue(configured.activeModelDetectsLanguage)
        assertTrue(configured.activeModelLanguages.contains("uk"))
        // Hindi is not one of the 25, so it still falls back.
        assertEquals(
            TranscriptionLanguage.AUTOMATIC,
            settings(TranscriptionLanguage.HINDI, localModelId = "parakeet-tdt-0.6b-v3")
                .effectiveLanguage,
        )
    }

    @Test
    fun aNarrowLocalModelAllowsOnlyItsOwnLanguages() {
        assertEquals(
            TranscriptionLanguage.GERMAN,
            settings(TranscriptionLanguage.GERMAN, localModelId = "canary-180m-flash")
                .effectiveLanguage,
        )
        assertEquals(
            TranscriptionLanguage.AUTOMATIC,
            settings(TranscriptionLanguage.HINDI, localModelId = "canary-180m-flash")
                .effectiveLanguage,
        )
    }

    @Test
    fun theGatewayClaimStillAppliesWhenOnDeviceIsOff() {
        val configured = settings(
            TranscriptionLanguage.HINDI,
            localModelId = "large-v3-turbo-q8_0",
            localEnabled = false,
            gatewayLanguages = setOf("en"),
        )
        assertEquals(TranscriptionLanguage.AUTOMATIC, configured.effectiveLanguage)
        assertEquals(setOf("en"), configured.activeModelLanguages)
    }

    /**
     * The point of declaring Parakeet's coverage: every one of its 25 languages
     * has to be a row the user can actually reach.
     */
    @Test
    fun everyLanguageParakeetCoversHasAPickerEntry() {
        val picker = TranscriptionLanguage.entries.map { it.wireValue }.toSet()
        val parakeet = LocalModelCatalog.find("parakeet-tdt-0.6b-v3")!!
        assertEquals(25, parakeet.languageCodes.size)
        assertTrue(
            "missing picker entries: ${parakeet.languageCodes - picker}",
            picker.containsAll(parakeet.languageCodes),
        )
        for (model in LocalModelCatalog.all) {
            assertTrue(
                "${model.id} covers codes the picker cannot show: " +
                    "${model.languageCodes - picker}",
                picker.containsAll(model.languageCodes),
            )
        }
    }

    /**
     * Cantonese is language 100. Offering it on a Whisper build that stops at 99
     * would not fail, it would silently decode against the wrong token.
     */
    @Test
    fun cantoneseIsOfferedOnlyWhereItDecodes() {
        val cantonese = TranscriptionLanguage.CANTONESE
        assertEquals(
            TranscriptionLanguage.AUTOMATIC,
            settings(cantonese, localModelId = "small-q8_0").effectiveLanguage,
        )
        assertEquals(
            cantonese,
            settings(cantonese, localModelId = "large-v3-turbo-q8_0").effectiveLanguage,
        )
        assertEquals(
            cantonese,
            settings(cantonese, localModelId = "sense-voice").effectiveLanguage,
        )
        // Everything else the pre-v3 builds cover is still on offer.
        assertEquals(
            TranscriptionLanguage.HINDI,
            settings(TranscriptionLanguage.HINDI, localModelId = "small-q8_0").effectiveLanguage,
        )
    }

    @Test
    fun anUnknownLocalModelIdFallsBackToNoClaim() {
        val configured = settings(TranscriptionLanguage.HINDI, localModelId = "not-a-model")
        assertEquals(TranscriptionLanguage.HINDI, configured.effectiveLanguage)
        assertNull(LocalModelCatalog.find("not-a-model"))
    }
}
