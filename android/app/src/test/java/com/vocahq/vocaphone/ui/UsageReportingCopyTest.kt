package com.vocahq.vocaphone.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the claims the usage-reporting copy has to keep making.
 *
 * A copy edit that quietly drops "your gateway's address" from the never-sent
 * list does not break a build or fail any other test — it just leaves the app
 * promising less than it actually does, in the one place users look to decide
 * whether to trust it.
 */
class UsageReportingCopyTest {

    @Test
    fun `the never-sent list names every category users actually worry about`() {
        val copy = UsageReportingCopy.WHAT_IS_NEVER_SENT.lowercase()

        listOf("what you say", "what you type", "transcripts", "audio", "gateway", "device model")
            .forEach { claim ->
                assertTrue("the never-sent list must still name $claim", copy.contains(claim))
            }
    }

    /**
     * The sentence that carries the whole anonymity story. It is true because
     * Aptabase derives its user hash from a salt it discards every 24 hours,
     * and it stops being true the moment anyone adds a stored identifier.
     */
    @Test
    fun `the copy claims no stored identifier and no cross-day linkage`() {
        val copy = UsageReportingCopy.WHAT_IS_NEVER_SENT.lowercase()

        assertTrue(copy.contains("stores nothing on your phone to identify you"))
        assertTrue(copy.contains("linked to anything"))
    }

    @Test
    fun `the sent list is specific rather than reassuring`() {
        val copy = UsageReportingCopy.WHAT_IS_SENT.lowercase()

        listOf("setup step", "succeeded or failed", "app version").forEach { claim ->
            assertTrue("the sent list must name $claim", copy.contains(claim))
        }
        // "Anonymous usage data" as the whole explanation is what this screen
        // exists not to say.
        assertFalse(copy.contains("anonymous usage data"))
    }

    /**
     * Disclosed rather than discovered. A `telemetry_disabled` event that a user
     * finds by packet capture is far more damaging than not knowing the opt-out
     * rate at all.
     */
    @Test
    fun `the opt-out event is disclosed in the copy`() {
        val copy = UsageReportingCopy.OPT_OUT_IS_LOGGED.lowercase()

        assertTrue(copy.contains("turning this off sends one last event"))
        assertTrue(copy.contains("opt out"))
    }

    @Test
    fun `both answers are offered as equals`() {
        assertTrue(UsageReportingCopy.TURN_ON.isNotBlank())
        assertTrue(UsageReportingCopy.NOT_NOW.isNotBlank())
        // Nothing that frames declining as a loss or a mistake.
        listOf(UsageReportingCopy.TURN_ON, UsageReportingCopy.NOT_NOW).forEach { label ->
            listOf("no thanks", "don't help", "skip", "later maybe").forEach { discouraging ->
                assertFalse(label.lowercase().contains(discouraging))
            }
        }
    }

    @Test
    fun `the settings screen explains why there is no reset button`() {
        assertTrue(UsageReportingCopy.NO_IDENTIFIER.lowercase().contains("no reporting id"))
    }
}
