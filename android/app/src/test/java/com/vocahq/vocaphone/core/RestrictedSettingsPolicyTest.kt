package com.vocahq.vocaphone.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RestrictedSettingsPolicyTest {

    private fun needed(
        sdkInt: Int = 33,
        installerPackage: String? = null,
        accessibilityGranted: Boolean = false,
    ) = RestrictedSettingsPolicy.guidanceNeeded(sdkInt, installerPackage, accessibilityGranted)

    @Test
    fun `a sideloaded install on Android 13 gets the guidance`() {
        // The release-page download: no installer recorded at all.
        assertTrue(needed(sdkInt = 33, installerPackage = null))
    }

    @Test
    fun `installing through a file manager or browser still gets the guidance`() {
        assertTrue(needed(installerPackage = "com.google.android.packageinstaller"))
        assertTrue(needed(installerPackage = "com.android.packageinstaller"))
        assertTrue(needed(installerPackage = "org.mozilla.firefox"))
    }

    @Test
    fun `the Play Store is exempt`() {
        assertFalse(needed(installerPackage = "com.android.vending"))
    }

    @Test
    fun `nothing is explained once the service is already on`() {
        assertFalse(needed(accessibilityGranted = true))
        assertFalse(needed(installerPackage = null, accessibilityGranted = true))
    }

    @Test
    fun `releases before Android 13 never restricted the switch`() {
        assertFalse(needed(sdkInt = 32))
        assertFalse(needed(sdkInt = 31, installerPackage = null))
    }

    @Test
    fun `an unrecognised installer is treated as restricted rather than exempt`() {
        // Guessing "exempt" strands the user with a greyed-out switch and no
        // explanation; guessing "restricted" only shows a paragraph they skip.
        assertTrue(needed(installerPackage = "com.some.unknown.store"))
    }
}
