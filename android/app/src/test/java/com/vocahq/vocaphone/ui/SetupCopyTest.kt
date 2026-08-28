package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupCopyTest {

    @Test
    fun setupLogoIsTheExistingVectorNotTheAdaptiveMipmap() {
        assertEquals(R.drawable.ic_vocaphone_logo, SetupCopy.LOGO)
        assertTrue(SetupCopy.LOGO != R.mipmap.ic_launcher)
    }

    @Test
    fun firstRunDefaultsToOnThisPhone() {
        assertTrue(VocaPhoneSettings().localTranscriptionEnabled)
        assertFalse(VocaPhoneSettings().isConfigured)
    }

    @Test
    fun introStaysShortAndPlain() {
        val copy = listOf(
            SetupCopy.TITLE,
            SetupCopy.INTRO,
            SetupCopy.START,
            SetupCopy.DOWNLOAD,
            SetupCopy.DOWNLOAD_AND_CONTINUE,
            SetupCopy.HELP_ME_CHOOSE,
            SetupCopy.BROWSE_MODELS,
            SetupCopy.BROWSE_SHEET_TITLE,
            SetupCopy.BROWSE_SHEET_SUPPORTING,
            SetupCopy.SLOW_ON_PHONES,
            SetupCopy.SLOW_ON_PHONES_DETAIL,
            MORE_MODELS_LABEL,
            SetupCopy.keyboardTapHint(ImeSetupStatus()).orEmpty(),
            SetupCopy.keyboardTapHint(ImeSetupStatus(enabled = true)).orEmpty(),
            SetupCopy.stepReady(SetupStep.MICROPHONE),
            SetupCopy.stepReady(SetupStep.NOTIFICATIONS),
            SetupCopy.stepReady(SetupStep.KEYBOARD),
            SetupCopy.stepReady(SetupStep.GATEWAY),
        )
        copy.forEach { line ->
            assertTrue(line.isNotBlank())
            assertFalse(line.contains("—"))
            assertFalse(line.contains("–"))
            assertFalse(line.contains("SHA-256"))
            assertFalse(line.contains("InputConnection"))
            assertFalse(line.contains("gateway you control"))
        }
        assertTrue(SetupCopy.INTRO.length < 90)
    }

    @Test
    fun keyboardCardHasOneStatusAndOneAction() {
        val off = ImeSetupStatus()
        val enabled = ImeSetupStatus(enabled = true)
        val selected = ImeSetupStatus(enabled = true, selected = true)

        assertEquals("Turn on the VocaPhone keyboard.", SetupCopy.keyboardStatus(off))
        assertEquals("Enable keyboard", SetupCopy.keyboardAction(off))
        assertEquals("Choose VocaPhone from the keyboard list.", SetupCopy.keyboardStatus(enabled))
        assertEquals("Choose VocaPhone keyboard", SetupCopy.keyboardAction(enabled))
        assertEquals("VocaPhone is the selected keyboard.", SetupCopy.keyboardStatus(selected))
        assertNull(SetupCopy.keyboardAction(selected))
        assertEquals("In keyboard settings, turn on VocaPhone.", SetupCopy.keyboardTapHint(off))
        assertEquals("Pick VocaPhone from the list that appears.", SetupCopy.keyboardTapHint(enabled))
        assertNull(SetupCopy.keyboardTapHint(selected))
    }
}
