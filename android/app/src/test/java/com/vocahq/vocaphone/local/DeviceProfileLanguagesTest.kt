package com.vocahq.vocaphone.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The recommendation keyed to every language a person uses, not only the
 * phone's UI language. Most bilingual people run their phone in English and
 * type in something else; before this the English-only model led for exactly
 * the users it could not serve.
 */
class DeviceProfileLanguagesTest {

    /** A phone that can run the 0.6B Parakeet encoder. */
    private fun phone(languages: List<String>) = DeviceProfile(
        totalRamGB = 8,
        cpuCores = 8,
        abi = "arm64-v8a",
        sherpaAvailable = true,
        language = languages.first(),
        languages = languages,
    )

    private fun picks(languages: List<String>) =
        LocalModelCatalog.recommendations(phone(languages)).map { it.model.id }

    // --- the regression guard ---------------------------------------------

    /**
     * A phone with only English gets exactly what it got before this change:
     * the field defaults to the primary alone, and the English path is taken.
     */
    @Test
    fun anEnglishOnlyPhoneIsUnchanged() {
        val before = DeviceProfile(totalRamGB = 8, cpuCores = 8, abi = "arm64-v8a", sherpaAvailable = true, language = "en")
        val after = phone(listOf("en"))
        assertTrue(before.englishOnly)
        assertEquals(listOf("en"), before.languages)
        assertEquals(
            LocalModelCatalog.recommendations(before).map { it.model.id },
            LocalModelCatalog.recommendations(after).map { it.model.id },
        )
        assertEquals("parakeet-tdt-0.6b-v2-en", picks(listOf("en")).first())
    }

    // --- the reported case ------------------------------------------------

    /** English UI, Russian keyboard: the person is a Russian speaker. */
    @Test
    fun anEnglishPhoneWithARussianKeyboardIsNotOfferedEnglishFirst() {
        val ids = picks(listOf("en", "ru"))
        assertFalse("English-only must not lead", ids.first() == "parakeet-tdt-0.6b-v2-en")
        assertTrue("the Russian specialist is offered", "giga-am-v3-ru" in ids)
        assertTrue("the multilingual Parakeet covers both", "parakeet-tdt-0.6b-v3" in ids)
        assertTrue("English-only is still there for the English half", "parakeet-tdt-0.6b-v2-en" in ids)
    }

    /**
     * The 25-language Parakeet does not cover Hindi, so on an English+Hindi
     * phone it must not be the multilingual pick — something that actually
     * covers Hindi must be.
     */
    @Test
    fun aLanguageOutsideParakeetsCoverageGetsAModelThatCoversIt() {
        val profile = phone(listOf("en", "hi"))
        val multilingual = LocalModelCatalog.bestMultilingual(profile)
        assertTrue("a multilingual model is still found", multilingual != null)
        assertTrue("and it covers Hindi", multilingual!!.coversLanguage("hi"))
        assertFalse(
            "the European-only Parakeet is not passed off as covering Hindi",
            multilingual.id == "parakeet-tdt-0.6b-v3",
        )
    }

    // --- shape of the list ------------------------------------------------

    @Test
    fun languagesAreNormalisedPrimaryFirstAndDeduplicated() {
        assertEquals(
            listOf("en", "ru", "hi"),
            DeviceProfile.normalizeLanguages("en", listOf("EN", "en-US", "ru_RU", "", " hi ", "ru")),
        )
    }

    @Test
    fun theProfilesEnglishOnlyFlagFollowsTheWholeList() {
        assertTrue(phone(listOf("en")).englishOnly)
        assertFalse(phone(listOf("en", "de")).englishOnly)
        assertFalse(phone(listOf("de")).englishOnly)
    }

    @Test
    fun coversAllRequiresEveryLanguage() {
        val parakeetV3 = LocalModelCatalog.find("parakeet-tdt-0.6b-v3")!!
        assertTrue(parakeetV3.coversAll(listOf("en", "de", "fr")))
        assertFalse(parakeetV3.coversAll(listOf("en", "hi")))
        assertTrue("empty is no restriction", parakeetV3.coversAll(emptyList()))
    }

    // --- an explicit choice overrides detection ---------------------------

    /**
     * Someone who picks Hindi by hand on an English-only phone must get the
     * Hindi path, not the English one the detected list would choose.
     */
    @Test
    fun aHandPickedLanguageReplacesTheDetectedList() {
        val hindi = phone(listOf("en")).withExplicitLanguage("Hindi".lowercase().take(2))
        assertEquals(listOf("hi"), hindi.languages)
        assertFalse(hindi.englishOnly)
        val ids = LocalModelCatalog.recommendations(hindi).map { it.model.id }
        assertFalse("English-only must not lead a Hindi request", ids.first() == "parakeet-tdt-0.6b-v2-en")
        assertTrue(LocalModelCatalog.find(ids.first())!!.coversLanguage("hi"))
    }

    @Test
    fun guidanceOnAutomaticKeepsEveryDetectedLanguage() {
        val profile = phone(listOf("en", "ru"))
        val result = ModelGuidance.recommend(
            profile,
            ModelGuidanceIntent(language = com.vocahq.vocaphone.core.TranscriptionLanguage.AUTOMATIC.wireValue),
        )
        assertTrue(result.model != null)
        assertTrue("the automatic pick must cover the keyboard language too", result.model!!.coversLanguage("ru"))
    }

    @Test
    fun subtypesThatAreNotLanguagesAreDropped() {
        assertEquals(
            listOf("en", "ru"),
            DeviceProfile.normalizeLanguages(
                "en",
                listOf("en_US", "emoji", "und-dictation", "vocaphone", "ru_RU", "zz", "en_US.UTF-8"),
            ),
        )
    }

    @Test
    fun scriptAndRegionVariantsCollapseToTheCatalogCode() {
        assertEquals("zh", catalogLanguageCode("zh-Hant-TW"))
        assertEquals("zh", catalogLanguageCode("zh_CN"))
        assertEquals("en", catalogLanguageCode("en-GB"))
        assertEquals("en", catalogLanguageCode("en_US@calendar=gregorian"))
    }

    @Test
    fun filipinoMapsToTheCatalogsCode() {
        assertEquals("tl", catalogLanguageCode("fil-PH"))
    }

    @Test
    fun codesNoModelCanClaimAreDroppedRatherThanCarried() {
        assertEquals(null, catalogLanguageCode("und"))
        assertEquals(null, catalogLanguageCode("mul"))
        assertEquals(null, catalogLanguageCode("auto"))
        assertEquals(null, catalogLanguageCode("xx-nowhere"))
        assertEquals(null, catalogLanguageCode(""))
        assertEquals(null, catalogLanguageCode(null))
    }

    @Test
    fun anUnknownPrimaryIsKeptButAnUnknownSecondaryIsNot() {
        assertEquals(listOf("xx", "ru"), DeviceProfile.normalizeLanguages("xx", listOf("ru", "yy")))
    }

    // --- the picker's path: the intent arrives unresolved -----------------

    /**
     * The picker hands guidance the raw selection — "auto" or a code — and
     * guidance resolves it. This is the case the emulator walk missed: an
     * English-UI phone with a Russian keyboard, automatic language. The lead
     * card must cover Russian, and the result must say the language was
     * detected rather than chosen.
     */
    @Test
    fun anAutomaticIntentReachesTheKeyboardLanguages() {
        val profile = phone(listOf("en", "ru"))
        val result = ModelGuidance.recommend(
            profile,
            ModelGuidanceIntent(language = com.vocahq.vocaphone.core.TranscriptionLanguage.AUTOMATIC.wireValue),
        )
        assertFalse("automatic is not explicit", result.explicitLanguage)
        assertTrue("the lead model covers the keyboard language", result.model!!.coversLanguage("ru"))
    }

    @Test
    fun choosingThePrimaryLanguageByHandIsStillExplicit() {
        val profile = phone(listOf("en", "ru"))
        val result = ModelGuidance.recommend(profile, ModelGuidanceIntent(language = "en"))
        assertTrue("a hand-picked code is explicit even when it equals the primary", result.explicitLanguage)
        assertEquals("en", result.intent.language)
        val picks = LocalModelCatalog.recommendations(
            if (result.explicitLanguage) profile.withExplicitLanguage(result.intent.language) else profile,
        ).map { it.model.id }
        assertEquals("parakeet-tdt-0.6b-v2-en", picks.first())
    }

    @Test
    fun aBlankIntentIsAutomatic() {
        val result = ModelGuidance.recommend(phone(listOf("en", "ru")), ModelGuidanceIntent(language = ""))
        assertFalse(result.explicitLanguage)
    }
}
