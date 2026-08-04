package io.github.mrsunglasses.localflow.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupStatusTest {

    private val complete = SetupStatus(
        microphone = true,
        notifications = true,
        overlay = true,
        accessibility = true,
        gatewayConfigured = true,
        disclosureAccepted = true,
    )

    @Test
    fun `every required step satisfied is ready to dictate`() {
        assertTrue(complete.isReadyToDictate)
        assertTrue(complete.remainingSteps.isEmpty())
        assertEquals(complete.stepCount, complete.completedStepCount)
    }

    @Test
    fun `battery is offered, never required`() {
        assertFalse(complete.batteryUnrestricted)
        assertTrue(complete.isReadyToDictate)
        assertTrue(complete.copy(batteryUnrestricted = true).isReadyToDictate)
    }

    @Test
    fun `remaining steps name what is left, in checklist order`() {
        val status = complete.copy(disclosureAccepted = false, gatewayConfigured = false)

        assertFalse(status.isReadyToDictate)
        assertEquals(listOf(SetupStep.DISCLOSURE, SetupStep.GATEWAY), status.remainingSteps)
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
