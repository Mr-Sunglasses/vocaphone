package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RecordingLimitTest {

    private val margin = RecordingLimit.GATEWAY_MARGIN_MILLIS

    @Test
    fun `the setting offers one to ten minutes and keeps five as the default`() {
        assertEquals(listOf(1, 2, 5, 10), MaximumRecordingLength.entries.map { it.minutes })
        assertEquals(MaximumRecordingLength.FIVE, MaximumRecordingLength.DEFAULT)
        assertEquals(MaximumRecordingLength.TEN, MaximumRecordingLength.LONGEST)
        assertEquals(MaximumRecordingLength.FIVE, MaximumRecordingLength.fromMinutes(null))
        assertEquals(MaximumRecordingLength.FIVE, MaximumRecordingLength.fromMinutes(7))
        assertEquals(MaximumRecordingLength.TEN, MaximumRecordingLength.fromMinutes(10))
        assertEquals("1 minute", MaximumRecordingLength.ONE.displayName)
        assertEquals("10 minutes", MaximumRecordingLength.TEN.displayName)
    }

    @Test
    fun `on the phone the setting alone decides`() {
        for (choice in MaximumRecordingLength.entries) {
            assertEquals(choice.millis, RecordingLimit.effectiveMillis(choice, onDevice = true, gatewayReportedSeconds = 60))
            assertEquals(choice.millis, RecordingLimit.effectiveMillis(choice, onDevice = true, gatewayReportedSeconds = null))
        }
    }

    @Test
    fun `a gateway route stops at the shorter of the setting and the gateway`() {
        // Gateway allows more than the choice: the choice.
        assertEquals(
            MaximumRecordingLength.TWO.millis,
            RecordingLimit.effectiveMillis(MaximumRecordingLength.TWO, onDevice = false, gatewayReportedSeconds = 300),
        )
        // Gateway allows less: the gateway, less the cue margin.
        assertEquals(
            300_000L - margin,
            RecordingLimit.effectiveMillis(MaximumRecordingLength.TEN, onDevice = false, gatewayReportedSeconds = 300),
        )
        // Equal: the margin still applies so the WAV, cue included, fits.
        assertEquals(
            300_000L - margin,
            RecordingLimit.effectiveMillis(MaximumRecordingLength.FIVE, onDevice = false, gatewayReportedSeconds = 300),
        )
        assertEquals(
            MaximumRecordingLength.TEN.millis,
            RecordingLimit.effectiveMillis(MaximumRecordingLength.TEN, onDevice = false, gatewayReportedSeconds = 900),
        )
    }

    @Test
    fun `a gateway that does not report a limit is assumed to take two minutes`() {
        assertEquals(120, RecordingLimit.gatewaySeconds(null))
        assertEquals(120, RecordingLimit.gatewaySeconds(0))
        assertEquals(
            120_000L - margin,
            RecordingLimit.effectiveMillis(MaximumRecordingLength.FIVE, onDevice = false, gatewayReportedSeconds = null),
        )
        assertEquals(
            MaximumRecordingLength.ONE.millis,
            RecordingLimit.effectiveMillis(MaximumRecordingLength.ONE, onDevice = false, gatewayReportedSeconds = null),
        )
    }

    @Test
    fun `the warning comes a minute before the stop, and only on longer limits`() {
        assertNull(RecordingLimit.warningAtMillis(MaximumRecordingLength.ONE.millis))
        assertNull(RecordingLimit.warningAtMillis(MaximumRecordingLength.TWO.millis))
        // An unreporting gateway's limit is short too.
        assertNull(RecordingLimit.warningAtMillis(120_000L - margin))
        assertEquals(4 * 60_000L, RecordingLimit.warningAtMillis(MaximumRecordingLength.FIVE.millis))
        assertEquals(9 * 60_000L, RecordingLimit.warningAtMillis(MaximumRecordingLength.TEN.millis))
        assertEquals(300_000L - margin - 60_000L, RecordingLimit.warningAtMillis(300_000L - margin))
    }

    @Test
    fun `Settings notes a gateway limit only when it is the shorter one`() {
        assertEquals(
            "Your gateway accepts up to 2 minutes. Update the gateway and test the connection to record longer.",
            RecordingLimit.gatewayNote(MaximumRecordingLength.FIVE, onDevice = false, gatewayReportedSeconds = null),
        )
        assertEquals(
            "Your gateway accepts up to 5 minutes. Raise its duration limit to record longer.",
            RecordingLimit.gatewayNote(MaximumRecordingLength.TEN, onDevice = false, gatewayReportedSeconds = 300),
        )
        assertEquals(
            "Your gateway accepts up to 90 seconds. Raise its duration limit to record longer.",
            RecordingLimit.gatewayNote(MaximumRecordingLength.TWO, onDevice = false, gatewayReportedSeconds = 90),
        )
        assertNull(RecordingLimit.gatewayNote(MaximumRecordingLength.TWO, onDevice = false, gatewayReportedSeconds = null))
        assertNull(RecordingLimit.gatewayNote(MaximumRecordingLength.FIVE, onDevice = false, gatewayReportedSeconds = 300))
        assertNull(RecordingLimit.gatewayNote(MaximumRecordingLength.TEN, onDevice = true, gatewayReportedSeconds = null))
    }
}
