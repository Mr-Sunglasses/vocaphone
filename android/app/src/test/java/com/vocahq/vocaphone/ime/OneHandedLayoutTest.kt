package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.settings.OneHandedMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OneHandedLayoutTest {
    @Test
    fun onlyAPhoneHeldUpright() {
        assertTrue(OneHandedLayout.active(OneHandedMode.LEFT, smallestWidthDp = 411, portrait = true))
        assertFalse(OneHandedLayout.active(OneHandedMode.LEFT, smallestWidthDp = 411, portrait = false))
        assertFalse(OneHandedLayout.active(OneHandedMode.RIGHT, smallestWidthDp = 673, portrait = true))
        assertFalse(OneHandedLayout.active(OneHandedMode.OFF, smallestWidthDp = 411, portrait = true))
    }

    @Test
    fun theMenuTileTogglesAndTheStripSwitchesSides() {
        assertEquals(OneHandedMode.RIGHT, OneHandedLayout.toggled(OneHandedMode.OFF))
        assertEquals(OneHandedMode.OFF, OneHandedLayout.toggled(OneHandedMode.LEFT))
        assertEquals(OneHandedMode.LEFT, OneHandedLayout.otherSide(OneHandedMode.RIGHT))
        assertEquals(OneHandedMode.RIGHT, OneHandedLayout.otherSide(OneHandedMode.LEFT))
    }

    @Test
    fun storedValuesReadBack() {
        OneHandedMode.entries.forEach { assertEquals(it, OneHandedMode.fromStored(it.storedValue)) }
        assertEquals(OneHandedMode.OFF, OneHandedMode.fromStored(null))
    }
}
