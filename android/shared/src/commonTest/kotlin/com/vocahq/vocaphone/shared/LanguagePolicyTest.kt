package com.vocahq.vocaphone.shared

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LanguagePolicyTest {
    private val dolphin = "bn\nhi\nja\nta\nzh"

    @Test
    fun explicitSelectionWinsExceptForAutomatic() {
        assertEquals("hi", LanguagePolicy.transcriptLanguage("hi", "en", "auto"))
        assertEquals("hi", LanguagePolicy.transcriptLanguage("auto", "hi", "auto"))
        assertEquals("de", LanguagePolicy.outputLanguage("hi", "en", "de", "auto"))
    }

    @Test
    fun coverageControlsSelectionButAnUnknownModelDoesNotLockThePicker() {
        assertTrue(LanguagePolicy.isSelectable("hi", "auto", dolphin))
        assertFalse(LanguagePolicy.isSelectable("fr", "auto", dolphin))
        assertTrue(LanguagePolicy.isSelectable("fr", "auto", ""))
        assertEquals("auto", LanguagePolicy.resolve("fr", "auto", dolphin))
    }

    @Test
    fun restrictionExplainsCoverageAndTranslation() {
        val restriction = LanguagePolicy.restriction(dolphin, false, false, true)
        assertTrue(restriction.contains("The on-device model covers 5 languages."))
        assertTrue(restriction.contains("not the language you want back"))
        assertTrue(restriction.contains("cannot translate"))
    }
}
