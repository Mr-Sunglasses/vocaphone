package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.TranscriptionLanguage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelChoicesTest {
    private fun profile(ram: Long, language: String = "en") = DeviceProfile(
        totalRamGB = ram,
        abi = "arm64-v8a",
        sherpaAvailable = true,
        language = language,
    )

    @Test
    fun theFirstRowIsWhatGuidanceWouldPick() {
        val choices = ModelChoices.choices(profile(8), "en")
        val guided = ModelGuidance.recommend(profile(8), ModelGuidanceIntent("en")).model
        assertEquals(ModelChoices.Kind.BEST, choices.first().kind)
        assertEquals(guided?.id, choices.first().model.id)
    }

    /**
     * Every language, every memory size: each row covers the language, fits,
     * appears once; the smaller row really is smaller, and the wider row
     * really hears more than the best one.
     */
    @Test
    fun choicesHoldTheirPromisesForEveryLanguage() {
        for (language in TranscriptionLanguage.entries.filter { it != TranscriptionLanguage.AUTOMATIC }) {
            for (ram in listOf(2L, 3L, 4L, 6L, 8L, 12L)) {
                val profile = profile(ram)
                val choices = ModelChoices.choices(profile, language.wireValue)
                val best = choices.firstOrNull() ?: continue
                assertEquals(ModelChoices.Kind.BEST, best.kind)
                assertEquals(choices.size, choices.map { it.model.id }.toSet().size)
                val lead = ModelGuidance.recommend(profile, ModelGuidanceIntent(language.wireValue)).intent.language
                for (choice in choices.drop(1)) {
                    assertTrue("${choice.model.id} for $lead", choice.model.coversLanguage(lead))
                    assertTrue(profile.fits(choice.model))
                }
                choices.firstOrNull { it.kind == ModelChoices.Kind.SMALLER }?.let {
                    assertTrue(it.model.sizeBytes < best.model.sizeBytes * ModelChoices.SMALLER_SHARE)
                }
                choices.firstOrNull { it.kind == ModelChoices.Kind.MORE_LANGUAGES }?.let {
                    assertFalse(it.model.englishOnly)
                    assertTrue(
                        it.model.languageCodes.isEmpty() ||
                            (best.model.languageCodes.isNotEmpty() &&
                                it.model.languageCodes.size > best.model.languageCodes.size) ||
                            best.model.englishOnly,
                    )
                }
            }
        }
    }

    @Test
    fun englishOnABigPhoneOffersAllThreeRows() {
        val kinds = ModelChoices.choices(profile(8), "en").map { it.kind }
        assertEquals(listOf(ModelChoices.Kind.BEST, ModelChoices.Kind.SMALLER, ModelChoices.Kind.MORE_LANGUAGES), kinds)
    }
}
