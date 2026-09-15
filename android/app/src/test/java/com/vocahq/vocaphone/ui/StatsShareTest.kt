package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.core.UsageStats
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StatsShareTest {
    private fun xPostLength(message: String): Int {
        val withoutUrl = message.replace("https://vocaphone.vocahq.com", "")
        val weighted = withoutUrl.codePoints().toArray().sumOf { codePoint ->
            if (codePoint in 0..4351 || codePoint in 8192..8205 || codePoint in 8208..8223 || codePoint in 8242..8247) 1 else 2
        }
        return weighted + 23
    }

    @Test
    fun messageContainsUsefulStatsAndPrivacyPromise() {
        val stats = UsageStats(
            totalWords = 1234,
            totalTranscriptions = 12,
            totalAudioMillis = 3_600_000,
            currentStreak = 3,
            lastDayKey = "2026-09-10",
        )
        val message = StatsShareComposer.message(stats, 1_789_012_800_000, StatsShareComposer.X_HANDLE)
        assertTrue(message.contains("I’ve spoken 1,234 words with VocaPhone"))
        assertTrue(message.contains("12 sessions"))
        assertTrue(message.contains("1 hour of talking"))
        assertTrue(message.contains("my phone or my own self-hosted gateway"))
        assertTrue(message.contains("My audio stays mine"))
        assertTrue(message.contains("@vocahq"))
    }

    @Test
    fun shareSheetMessageOmitsTheXHandle() {
        val message = StatsShareComposer.message(UsageStats(totalWords = 1), 0)
        assertFalse(message.contains("@vocahq"))
        assertTrue(message.endsWith("https://vocaphone.vocahq.com"))
    }

    @Test
    fun messageFitsWithinTheXPostLimit() {
        val stats = UsageStats(
            totalWords = 987_654_321,
            totalTranscriptions = 123_456,
            totalAudioMillis = 9_000_000_000,
            currentStreak = 4_321,
            bestStreak = 5_000,
            lastDayKey = "2026-09-10",
        )
        val message = StatsShareComposer.message(stats, 1_789_012_800_000, StatsShareComposer.X_HANDLE)
        assertTrue(message, xPostLength(message) <= 280)
    }

    @Test
    fun unavailableDetailsAndShortDurationsAreOmitted() {
        val stats = UsageStats(totalWords = 1, totalAudioMillis = 0)
        val message = StatsShareComposer.message(stats, 0)
        assertTrue(message.contains("1 word"))
        assertFalse(message.contains("session"))
        assertFalse(message.contains("talking"))
        assertFalse(message.contains("WPM"))
        assertFalse(message.contains("streak"))
        assertFalse(message.contains("\n\n\n"))
        assertNull(StatsShareComposer.spokenDuration(59_999))
        assertTrue(StatsShareComposer.spokenDuration(5_460_000) == "1 hour, 31 minutes")
    }

}
