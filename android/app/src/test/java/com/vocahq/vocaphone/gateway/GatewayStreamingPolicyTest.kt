package com.vocahq.vocaphone.gateway

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GatewayStreamingPolicyTest {
    @Test
    fun `fresh batch capability skips streaming negotiation`() {
        assertFalse(
            GatewayStreamingPolicy.shouldAttemptStreaming(
                supported = false,
                checkedAtMillis = 10_000L,
                nowMillis = 20_000L,
            )
        )
    }

    @Test
    fun `unknown or stale capability negotiates again`() {
        assertTrue(
            GatewayStreamingPolicy.shouldAttemptStreaming(
                supported = false,
                checkedAtMillis = null,
                nowMillis = 20_000L,
            )
        )
        assertTrue(
            GatewayStreamingPolicy.shouldAttemptStreaming(
                supported = false,
                checkedAtMillis = 10_000L,
                nowMillis = 10_000L + GatewayStreamingPolicy.CAPABILITY_FRESHNESS_MILLIS + 1,
            )
        )
        assertTrue(
            GatewayStreamingPolicy.shouldAttemptStreaming(
                supported = true,
                checkedAtMillis = 10_000L,
                nowMillis = 20_000L,
            )
        )
    }
}
