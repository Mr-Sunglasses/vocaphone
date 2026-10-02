package com.vocahq.vocaphone.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ImeSetupTest {
    @Test
    fun shortAndFullComponentIdsSelectTheSameKeyboard() {
        val pkg = "com.vocahq.vocaphone"
        val service = "$pkg.ime.VocaPhoneInputMethodService"
        assertTrue(ImeSetup.matchesComponent("$pkg/.ime.VocaPhoneInputMethodService", pkg, service))
        assertTrue(ImeSetup.matchesComponent("$pkg/$service", pkg, service))
        assertFalse(ImeSetup.matchesComponent("other.package/$service", pkg, service))
        assertFalse(ImeSetup.matchesComponent("$pkg/.ime.OtherService", pkg, service))
        assertFalse(ImeSetup.matchesComponent(null, pkg, service))
        assertFalse(ImeSetup.matchesComponent("", pkg, service))
    }


    /**
     * Guided setup's keyboard step is two separate system changes, and each one
     * has its own setting. Watching only the second is the shape of the bug this
     * list exists to prevent: the checklist would sit on "Turn on the VocaPhone
     * keyboard" after it had been turned on, with no way forward but killing the
     * app.
     *
     * The names rather than the URIs, because `Settings.Secure.getUriFor` needs
     * a framework this test does not have — and because the names are the part
     * that would be wrong.
     */
    @Test
    fun bothHalvesOfTheKeyboardStepAreWatched() {
        assertTrue(ImeSetup.WATCHED_SETTINGS.contains("enabled_input_methods"))
        assertTrue(ImeSetup.WATCHED_SETTINGS.contains("default_input_method"))
        assertEquals(2, ImeSetup.WATCHED_SETTINGS.size)
    }
}
