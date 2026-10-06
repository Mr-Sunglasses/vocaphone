package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupStatusTest {

    /** A finished checklist for whichever input path this flavor ships. */
    private val complete = if (BuildConfig.FLOATING_INPUT) {
        SetupStatus(
            microphone = true,
            notifications = true,
            disclosureAccepted = true,
            overlay = true,
            accessibility = true,
            gatewayConfigured = true,
        )
    } else {
        SetupStatus(
            microphone = true,
            notifications = true,
            keyboard = true,
            gatewayConfigured = true,
        )
    }

    /** The input step this flavor's checklist holds the user to. */
    private val incompleteInput = if (BuildConfig.FLOATING_INPUT) {
        complete.copy(accessibility = false)
    } else {
        complete.copy(keyboard = false)
    }

    private val inputStep = if (BuildConfig.FLOATING_INPUT) {
        SetupStep.ACCESSIBILITY
    } else {
        SetupStep.KEYBOARD
    }

    @Test
    fun `startup placeholder cannot claim readiness before settings are read`() {
        assertFalse(complete.copy(isLoaded = false).isReadyToDictate)
        assertTrue(complete.copy(isLoaded = true).isReadyToDictate)
    }

    @Test
    fun `every required step satisfied is ready to dictate`() {
        assertTrue(complete.isReadyToDictate)
        assertTrue(complete.remainingSteps.isEmpty())
        assertEquals(complete.stepCount, complete.completedStepCount)
    }

    @Test
    fun `the input step is required`() {
        assertTrue(complete.isReadyToDictate)
        assertFalse(incompleteInput.isReadyToDictate)
    }

    @Test
    fun `remaining steps name what is left, in checklist order`() {
        val status = incompleteInput.copy(gatewayConfigured = false)

        assertFalse(status.isReadyToDictate)
        assertEquals(listOf(inputStep, SetupStep.GATEWAY), status.remainingSteps)
        assertEquals(status.stepCount - 2, status.completedStepCount)
    }

    @Test
    fun `a fresh install has nothing done`() {
        val status = SetupStatus()

        assertFalse(status.isReadyToDictate)
        assertEquals(status.requiredSteps, status.remainingSteps)
        assertEquals(0, status.completedStepCount)
        assertEquals(
            if (BuildConfig.FLOATING_INPUT) {
                listOf(
                    "Accessibility disclosure",
                    "Microphone",
                    "Notifications",
                    "Display over other apps",
                    "Accessibility service",
                    "Speech source",
                )
            } else {
                listOf("Microphone", "Notifications", "VocaPhone keyboard", "Speech source")
            },
            status.remainingLabels,
        )
    }

    @Test
    fun `remaining labels name only the unfinished steps`() {
        val status = incompleteInput.copy(gatewayConfigured = false)

        assertEquals(listOf(inputStep.label, "Speech source"), status.remainingLabels)
        assertTrue(complete.remainingLabels.isEmpty())
    }

    @Test
    fun remainingLabelsSkipTheStillToDoSentence() {
        val status = complete.copy(gatewayConfigured = false)

        assertEquals(listOf("Speech source"), status.remainingLabels)
        assertFalse(status.remainingLabels.joinToString().contains("Still to do"))
    }
}
