package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.core.UsageStats
import org.junit.Assert.assertTrue
import org.junit.Test

class StatsShareTest {
    @Test
    fun messageContainsUsefulStatsAndPrivacyPromise() {
        val stats = UsageStats(totalWords = 1234, totalTranscriptions = 12, currentStreak = 3, lastDayKey = "2026-09-10")
        val message = StatsShareComposer.message(stats, 1_789_012_800_000)
        assertTrue(message.contains("1,234") || message.contains("1234"))
        assertTrue(message.contains("12 sessions"))
        assertTrue(message.contains("phone, privately"))
    }

    @Test
    fun destinationsHaveUserFacingLabels() {
        assertTrue(StatsShareDestination.X.label == "X")
        assertTrue(StatsShareDestination.LINKEDIN.label == "LinkedIn")
        assertTrue(StatsShareDestination.X.packageName == "com.twitter.android")
        assertTrue(StatsShareDestination.LINKEDIN.packageName == "com.linkedin.android")
    }
}
