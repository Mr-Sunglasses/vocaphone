package com.vocahq.vocaphone.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupStatusTest {

    private val complete = SetupStatus(
        microphone = true,
        notifications = true,
        keyboard = true,
        gatewayConfigured = true,
    )

    @Test
    fun `every required step satisfied is ready to dictate`() {
        assertTrue(complete.isReadyToDictate)
        assertTrue(complete.remainingSteps.isEmpty())
        assertEquals(complete.stepCount, complete.completedStepCount)
    }

    @Test
    fun `keyboard selection is required`() {
        assertTrue(complete.isReadyToDictate)
        assertFalse(complete.copy(keyboard = false).isReadyToDictate)
    }

    @Test
    fun `remaining steps name what is left, in checklist order`() {
        val status = complete.copy(keyboard = false, gatewayConfigured = false)

        assertFalse(status.isReadyToDictate)
        assertEquals(listOf(SetupStep.KEYBOARD, SetupStep.GATEWAY), status.remainingSteps)
        assertEquals(status.stepCount - 2, status.completedStepCount)
    }

    @Test
    fun `a fresh install has nothing done`() {
        val status = SetupStatus()

        assertFalse(status.isReadyToDictate)
        assertEquals(SetupStep.entries, status.remainingSteps)
        assertEquals(0, status.completedStepCount)
    }
}
