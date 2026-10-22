package com.vocahq.vocaphone.settings

import org.junit.Assert.assertFalse
import org.junit.Test

class VocaPhoneSettingsTest {

    @Test
    fun dynamicColorDefaultsOffSoBrandTealStays() {
        assertFalse(VocaPhoneSettings().dynamicColorEnabled)
    }

    /** A 28 MB download that can change a correct sentence is never on by itself. */
    @Test
    fun fixGrammarDefaultsOff() {
        assertFalse(VocaPhoneSettings().fixGrammar)
    }

    /** Same model, same reasons: reading what is typed is never on by itself. */
    @Test
    fun typingGrammarDefaultsOff() {
        assertFalse(VocaPhoneSettings().typingGrammar)
    }
}
