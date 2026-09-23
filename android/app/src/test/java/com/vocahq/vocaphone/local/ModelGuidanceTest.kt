package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.TranscriptionLanguage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelGuidanceTest {

    private val allLanguages = listOf("en", "ru", "de", "ja", "zh")


    private fun profile(
        ram: Long,
        sherpa: Boolean = true,
        language: String = "en",
    ) = DeviceProfile(
        totalRamGB = ram,
        abi = "arm64-v8a",
        sherpaAvailable = sherpa,
        language = language,
    )

    @Test
    fun balancedKeepsTheExistingCatalogDefault() {
        val result = ModelGuidance.recommend(
            profile(8),
            ModelGuidanceIntent("en", ModelGuidancePriority.BALANCED),
        )

        assertEquals(ModelGuidanceConfidence.GOOD_DEFAULT, result.confidence)
        assertEquals("parakeet-tdt-0.6b-v2-en", result.model?.id)
        assertTrue(result.reason.contains("English"))
    }

    @Test
    fun lighterPrefersTheSmallestCompatibleDownload() {
        val result = ModelGuidance.recommend(
            profile(8, sherpa = false, language = "de"),
            ModelGuidanceIntent("de", ModelGuidancePriority.LIGHTER),
        )

        assertEquals("tiny-q8_0", result.model?.id)
        assertEquals("German", result.languageName)
        assertTrue(result.downloadDetail?.contains("43 MB") == true)
    }








    /**
     * The reason this option exists at all. "Best accuracy" was replaced
     * because it returned the balanced match on every language and every tier,
     * which is a control that does nothing.
     *
     * A phone that cannot hold a wider model is the one honest exception, and
     * the reason text says so rather than pretending otherwise.
     */
    @Test
    fun multilingualIsADifferentAnswerWhereverAWiderModelFits() {
        var differed = 0
        allLanguages.forEach { language ->
            listOf(8L, 4L, 3L).forEach { ram ->
                val device = profile(ram, language = language)
                val balanced = ModelGuidance.recommend(
                    device,
                    ModelGuidanceIntent(language, ModelGuidancePriority.BALANCED),
                ).model
                val multilingual = ModelGuidance.recommend(
                    device,
                    ModelGuidanceIntent(language, ModelGuidancePriority.MULTILINGUAL),
                ).model

                assertNotNull("no multilingual match for $language at ${ram}GB", multilingual)
                if (multilingual?.id != balanced?.id) differed++
            }
        }
        // The option has to actually earn its place on ordinary phones.
        assertTrue("multilingual never differed from balanced anywhere", differed >= 10)
    }

    @Test
    fun multilingualCoversMoreThanOneLanguageAndStillTheRequestedOne() {
        allLanguages.forEach { language ->
            val result = ModelGuidance.recommend(
                profile(8, language = language),
                ModelGuidanceIntent(language, ModelGuidancePriority.MULTILINGUAL),
            )

            val model = result.model
            assertNotNull("no multilingual match for $language", model)
            assertTrue("$language pick cannot transcribe it", model!!.coversLanguage(language))
            assertTrue("$language pick is English-only", !model.englishOnly)
        }
    }

    @Test
    fun multilingualNeverReturnsAModelThePhoneCannotRun() {
        val device = profile(3, sherpa = false)
        val result = ModelGuidance.recommend(
            device,
            ModelGuidanceIntent("en", ModelGuidancePriority.MULTILINGUAL),
        )

        val model = result.model
        assertNotNull(model)
        assertTrue(device.fits(model!!))
    }

    @Test
    fun automaticLanguageUsesTheDeviceProfile() {
        val result = ModelGuidance.recommend(
            profile(8, language = "ru"),
            ModelGuidanceIntent("auto"),
        )

        assertEquals("ru", result.intent.language)
        assertEquals("giga-am-v3-ru", result.model?.id)
    }

    @Test
    fun explicitLanguageWinsOverTheDeviceLocale() {
        val result = ModelGuidance.recommend(
            profile(8, language = "en"),
            ModelGuidanceIntent("ru"),
        )

        assertEquals("ru", result.intent.language)
        assertTrue(result.model?.coversLanguage("ru") == true)
    }

    @Test
    fun anUnlistedPhoneLanguageIsNotMislabelledAsAutomatic() {
        val result = ModelGuidance.recommend(
            profile(8, language = "af"),
            ModelGuidanceIntent("auto"),
        )

        assertEquals("af", result.intent.language)
        assertTrue(result.languageName.isNotBlank())
        assertTrue(result.languageName != TranscriptionLanguage.AUTOMATIC.displayName)
    }

    @Test
    fun unsupportedLanguageReportsNoMatchWhenTheBuildHasNoSuitableRuntime() {
        val result = ModelGuidance.recommend(
            profile(3, sherpa = false, language = "yue"),
            ModelGuidanceIntent("yue"),
        )

        assertEquals(ModelGuidanceConfidence.NO_MATCH, result.confidence)
        assertEquals(null, result.model)
        assertTrue(result.reason.contains("Cantonese"))
        assertNotNull(result.languageName)
    }
}
