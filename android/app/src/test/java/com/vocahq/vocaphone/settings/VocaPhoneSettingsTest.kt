package com.vocahq.vocaphone.settings

import org.junit.Assert.assertFalse
import org.junit.Test

class VocaPhoneSettingsTest {

    @Test
    fun dynamicColorDefaultsOffSoBrandTealStays() {
        assertFalse(VocaPhoneSettings().dynamicColorEnabled)
    }
}
