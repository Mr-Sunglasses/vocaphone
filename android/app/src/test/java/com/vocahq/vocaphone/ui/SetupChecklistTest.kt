package com.vocahq.vocaphone.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupChecklistTest {

    @Test
    fun collapseSatisfiedAndLaterUnfinishedRows() {
        val next = SetupStatus().remainingSteps.first()
        assertEquals(SetupStep.MICROPHONE, next)

        assertTrue(
            collapseChecklistRow(satisfied = true, isNextUnfinished = false),
        )
        assertFalse(
            collapseChecklistRow(satisfied = false, isNextUnfinished = true),
        )
        assertTrue(
            collapseChecklistRow(satisfied = false, isNextUnfinished = false),
        )
        assertFalse(
            collapseChecklistRow(
                satisfied = true,
                isNextUnfinished = false,
                showingReady = true,
            ),
        )
    }

    @Test
    fun deniedAfterAskOpensAppSettings() {
        assertFalse(
            SetupPermissions.needsAppSettings(
                granted = false,
                asked = false,
                showRationale = false,
            ),
        )
        assertFalse(
            SetupPermissions.needsAppSettings(
                granted = false,
                asked = true,
                showRationale = true,
            ),
        )
        assertTrue(
            SetupPermissions.needsAppSettings(
                granted = false,
                asked = true,
                showRationale = false,
            ),
        )
        assertFalse(
            SetupPermissions.needsAppSettings(
                granted = true,
                asked = true,
                showRationale = false,
            ),
        )
    }

    @Test
    fun keyboardRepairFollowsTwoStepIme() {
        val off = ImeSetupStatus()
        val enabled = ImeSetupStatus(enabled = true)
        val selected = ImeSetupStatus(enabled = true, selected = true)

        assertEquals("Enable keyboard", SetupCopy.keyboardAction(off))
        assertEquals("Choose VocaPhone keyboard", SetupCopy.keyboardAction(enabled))
        assertEquals(null, SetupCopy.keyboardAction(selected))
    }
}
