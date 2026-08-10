package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import org.junit.Assert.assertEquals
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
            localModelId = "large-v3-turbo-q5_0",
            gatewayLanguages = setOf("en"),
        )
        assertEquals(TranscriptionLanguage.HINDI, configured.effectiveLanguage)
        assertTrue(configured.activeModelLanguages.isEmpty())
    }

    @Test
    fun aStaleGatewayAutoDetectClaimNoLongerForcesAutomatic() {
        val configured = settings(
            TranscriptionLanguage.GERMAN,
            localModelId = "large-v3-turbo-q5_0",
            gatewayDetects = true,
        )
        assertEquals(TranscriptionLanguage.GERMAN, configured.effectiveLanguage)
    }

    @Test
    fun anEnglishOnlyLocalModelStillRejectsOtherLanguages() {
        val configured = settings(TranscriptionLanguage.HINDI, localModelId = "small.en-q5_1")
        assertEquals(TranscriptionLanguage.AUTOMATIC, configured.effectiveLanguage)
        assertEquals(setOf("en"), configured.activeModelLanguages)
    }

    @Test
    fun anAutoDetectingLocalModelAllowsOnlyAutomatic() {
        val configured = settings(TranscriptionLanguage.ENGLISH, localModelId = "sense-voice")
        assertEquals(TranscriptionLanguage.AUTOMATIC, configured.effectiveLanguage)
        assertTrue(configured.activeModelDetectsLanguage)
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
            localModelId = "large-v3-turbo-q5_0",
            localEnabled = false,
            gatewayLanguages = setOf("en"),
        )
        assertEquals(TranscriptionLanguage.AUTOMATIC, configured.effectiveLanguage)
        assertEquals(setOf("en"), configured.activeModelLanguages)
    }

    @Test
    fun anUnknownLocalModelIdFallsBackToNoClaim() {
        val configured = settings(TranscriptionLanguage.HINDI, localModelId = "not-a-model")
        assertEquals(TranscriptionLanguage.HINDI, configured.effectiveLanguage)
        assertNull(LocalModelCatalog.find("not-a-model"))
    }
}
