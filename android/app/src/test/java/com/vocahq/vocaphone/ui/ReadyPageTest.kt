package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.local.LocalModelState
import org.junit.Assert.assertEquals
import org.junit.Test

class ReadyPageTest {
    private val parakeet = "parakeet-tdt-0.6b-v2-en"
    private val ready = SetupStatus(
        microphone = true, notifications = true, keyboard = true, gatewayConfigured = true,
    )
    private val inFlight = LocalModelState(downloading = parakeet, pendingUse = parakeet, progress = 8)
    private val landedNotAdopted = LocalModelState(downloaded = setOf(parakeet), pendingUse = parakeet)
    private val adopted = LocalModelState(downloaded = setOf(parakeet))

    @Test
    fun `download-and-use in flight waits`() {
        assertEquals(ReadyPagePresentation.WAITING_FOR_MODEL, readyPagePresentation(ready, true, inFlight))
    }

    @Test
    fun `landed but not yet adopted still waits`() {
        assertEquals(ReadyPagePresentation.WAITING_FOR_MODEL, readyPagePresentation(ready, true, landedNotAdopted))
    }

    @Test
    fun `adopted model is ready`() {
        assertEquals(ReadyPagePresentation.READY, readyPagePresentation(ready, true, adopted))
    }

    @Test
    fun `an unmet requirement wins over a pending download`() {
        // Cancel and failure clear pendingUse and the source requirement in
        // the same breath; if they ever raced, the page must still offer
        // review rather than a wait nothing ends.
        val status = ready.copy(gatewayConfigured = false)
        assertEquals(ReadyPagePresentation.NEEDS_ATTENTION, readyPagePresentation(status, true, inFlight))
        assertEquals(ReadyPagePresentation.NEEDS_ATTENTION, readyPagePresentation(status, true, LocalModelState()))
    }

    @Test
    fun `preparation failure reads as attention for a first-time user`() {
        val status = ready.copy(gatewayConfigured = false)
        val failed = LocalModelState(downloaded = setOf(parakeet), message = "Could not load Parakeet.")
        assertEquals(ReadyPagePresentation.NEEDS_ATTENTION, readyPagePresentation(status, true, failed))
    }

    @Test
    fun `preparation failure with an older working model is honestly ready`() {
        val failed = LocalModelState(downloaded = setOf(parakeet, "tiny"), message = "Could not load Parakeet.")
        assertEquals(ReadyPagePresentation.READY, readyPagePresentation(ready, true, failed))
    }

    @Test
    fun `gateway source never waits on a model`() {
        assertEquals(ReadyPagePresentation.READY, readyPagePresentation(ready, false, inFlight))
    }

    @Test
    fun `one missing step is named with its own verb`() {
        assertEquals(
            AttentionCopy("One more step", "Choose a speech model and you\u2019re done.", "Choose a model"),
            attentionCopy(listOf(SetupStep.GATEWAY)),
        )
        assertEquals("Allow microphone", attentionCopy(listOf(SetupStep.MICROPHONE)).button)
        assertEquals("Allow notifications", attentionCopy(listOf(SetupStep.NOTIFICATIONS)).button)
        assertEquals("Turn on keyboard", attentionCopy(listOf(SetupStep.KEYBOARD)).button)
    }

    @Test
    fun `several missing steps are listed and reviewed`() {
        val two = attentionCopy(listOf(SetupStep.MICROPHONE, SetupStep.KEYBOARD))
        assertEquals("Microphone and VocaPhone keyboard still need attention.", two.detail)
        assertEquals(SetupCopy.REVIEW, two.button)
        val three = attentionCopy(listOf(SetupStep.MICROPHONE, SetupStep.NOTIFICATIONS, SetupStep.GATEWAY))
        assertEquals("Microphone, Notifications and Speech source still need attention.", three.detail)
    }

    @Test
    fun `the attention button label is the one the copy chose`() {
        assertEquals("Choose a model", readyPageButtonLabel(ReadyPagePresentation.NEEDS_ATTENTION, null, "Choose a model"))
    }

    @Test
    fun `button label follows the presentation`() {
        assertEquals(SetupCopy.START, readyPageButtonLabel(ReadyPagePresentation.READY, null))
        assertEquals(SetupCopy.REVIEW, readyPageButtonLabel(ReadyPagePresentation.NEEDS_ATTENTION, null))
        assertEquals(
            "Downloading · 8% · 57 MB of 661 MB · about 5 minutes left",
            readyPageButtonLabel(ReadyPagePresentation.WAITING_FOR_MODEL, "8% · 57 MB of 661 MB · about 5 minutes left"),
        )
        // The second between landing and adoption has no bytes to report.
        assertEquals(SetupCopy.WAITING_PREPARING, readyPageButtonLabel(ReadyPagePresentation.WAITING_FOR_MODEL, null))
    }
}
