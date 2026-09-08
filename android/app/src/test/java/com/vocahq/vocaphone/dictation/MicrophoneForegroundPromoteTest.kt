package com.vocahq.vocaphone.dictation

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MicrophoneForegroundPromoteTest {

    @Test
    fun `retries stay under the startForegroundService timeout`() {
        val budgetMs = MicrophoneForegroundPromote.MAX_ATTEMPTS *
            MicrophoneForegroundPromote.RETRY_DELAY_MS
        assertTrue(budgetMs < 5_000L)
        assertTrue(MicrophoneForegroundPromote.shouldRetry(1))
        assertTrue(
            MicrophoneForegroundPromote.shouldRetry(MicrophoneForegroundPromote.MAX_ATTEMPTS - 1),
        )
        assertFalse(
            MicrophoneForegroundPromote.shouldRetry(MicrophoneForegroundPromote.MAX_ATTEMPTS),
        )
    }

    @Test
    fun `the visible activity is a later fallback not the first retry`() {
        assertFalse(MicrophoneForegroundPromote.shouldLaunchVisibleActivity(1))
        assertTrue(
            MicrophoneForegroundPromote.shouldLaunchVisibleActivity(
                MicrophoneForegroundPromote.LAUNCH_ACTIVITY_AFTER,
            ),
        )
        assertFalse(
            MicrophoneForegroundPromote.shouldLaunchVisibleActivity(
                MicrophoneForegroundPromote.LAUNCH_ACTIVITY_AFTER + 1,
            ),
        )
    }
}
