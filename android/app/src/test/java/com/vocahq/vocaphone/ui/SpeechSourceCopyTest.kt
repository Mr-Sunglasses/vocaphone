package com.vocahq.vocaphone.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeechSourceCopyTest {

    @Test
    fun localModelDoesNotLookLikeABrokenGateway() {
        val copy = speechSourceCopy(
            localEnabled = true,
            localModelName = "Whisper Tiny Q5",
            gatewayConfigured = false,
            gatewayUrl = "",
            lastEngine = "",
            lastEngineReady = false,
        )

        assertTrue(copy.localSelected)
        assertEquals("Whisper Tiny Q5", copy.localDetail)
        assertEquals("Not configured", copy.gatewayDetail)
        assertEquals("Gateway is off while you use a model on this phone.", copy.inactiveHint)
        assertEquals("On this phone · Whisper Tiny Q5", copy.engineLabel)
        assertFalse(copy.engineLabel.contains("unknown"))
        assertFalse(copy.engineLabel.contains("not ready"))
    }

    @Test
    fun localWithoutAModelStillNamesThePhone() {
        val copy = speechSourceCopy(
            localEnabled = true,
            localModelName = null,
            gatewayConfigured = true,
            gatewayUrl = "http://homelabone.local:8765",
        )

        assertEquals("No model on this phone yet", copy.localDetail)
        assertEquals("On this phone", copy.engineLabel)
        assertEquals("http://homelabone.local:8765", copy.gatewayDetail)
    }

    @Test
    fun gatewayShowsTheAddressAndMutesOnDevice() {
        val copy = speechSourceCopy(
            localEnabled = false,
            localModelName = "Whisper Tiny Q5",
            gatewayConfigured = true,
            gatewayUrl = "http://homelabone.local:8765",
            lastEngine = "moonshine:en",
            lastEngineReady = true,
        )

        assertFalse(copy.localSelected)
        assertEquals("On-device models are off while you use a gateway.", copy.inactiveHint)
        assertEquals("http://homelabone.local:8765", copy.gatewayDetail)
        assertEquals("moonshine:en (ready)", copy.engineLabel)
    }

    @Test
    fun firstRunPicksOnThisPhoneAndLeavesGatewayClosed() {
        val choice = speechSourceSelection(wantLocal = true, gatewayConfigured = false)

        assertTrue(choice.localEnabled)
        assertFalse(choice.openGateway)
    }

    @Test
    fun pickingGatewayOpensSetupWhenItIsNotConfigured() {
        val choice = speechSourceSelection(wantLocal = false, gatewayConfigured = false)

        assertFalse(choice.localEnabled)
        assertTrue(choice.openGateway)
    }

    @Test
    fun pickingAConfiguredGatewayDoesNotReopenSetup() {
        val choice = speechSourceSelection(wantLocal = false, gatewayConfigured = true)

        assertFalse(choice.localEnabled)
        assertFalse(choice.openGateway)
    }

    @Test
    fun unconfiguredGatewayIsNamedAsSuch() {
        val copy = speechSourceCopy(
            localEnabled = false,
            localModelName = null,
            gatewayConfigured = false,
            gatewayUrl = "",
        )

        assertEquals("Not configured", copy.gatewayDetail)
        assertEquals("unknown (not ready)", copy.engineLabel)
    }
}
