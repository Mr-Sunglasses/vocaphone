package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.core.UsageStats
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Test

class StatsFormatTest {

    private val utc: TimeZone = TimeZone.getTimeZone("UTC")
    private val en = Locale.US

    private fun at(year: Int, month: Int, day: Int, hour: Int = 12): Long {
        val calendar = Calendar.getInstance(utc, Locale.ROOT)
        calendar.clear()
        calendar.set(year, month - 1, day, hour, 0, 0)
        return calendar.timeInMillis
    }

    @Test
    fun largeCountsAreGrouped() {
        assertEquals("7,968", StatsFormat.count(7_968, en))
        assertEquals("0", StatsFormat.count(0, en))
    }

    @Test
    fun durationsDropEmptyLeadingUnitsButKeepSeconds() {
        assertEquals("1h 11m 11s", StatsFormat.duration(4_271_000, en))
        assertEquals("11m 11s", StatsFormat.duration(671_000, en))
        assertEquals("9s", StatsFormat.duration(9_000, en))
        assertEquals("0s", StatsFormat.duration(0, en))
    }

    @Test
    fun aNegativeDurationIsNotRenderedAsNegativeTime() {
        assertEquals("0s", StatsFormat.duration(-5_000, en))
    }

    @Test
    fun speakingSpeedKeepsOneDecimal() {
        assertEquals("111.9", StatsFormat.wordsPerMinute(111.94, en))
        assertEquals("0.0", StatsFormat.wordsPerMinute(0.0, en))
    }

    @Test
    fun unitsAreSingularWhereItReads() {
        assertEquals("1 day", StatsFormat.streak(1, en))
        assertEquals("11 days", StatsFormat.streak(11, en))
        assertEquals("1 word", StatsFormat.words(1, en))
        assertEquals("65 words", StatsFormat.words(65, en))
    }

    @Test
    fun theTwoDaysAPersonNamesAreNamed() {
        val now = at(2026, 9, 8)
        assertEquals("Today", StatsFormat.dayLabel("2026-09-08", now, en, utc))
        assertEquals("Yesterday", StatsFormat.dayLabel("2026-09-07", now, en, utc))
    }

    @Test
    fun olderDaysGetADate() {
        val now = at(2026, 9, 8)
        assertEquals("Sep 4, 2026", StatsFormat.dayLabel("2026-09-04", now, en, utc))
    }

    /**
     * The label is decided by comparing day keys rather than by subtracting 24
     * hours, so it stays right on the days daylight saving makes 23 or 25 hours
     * long. Sydney moves its clock forward on 2026-10-04.
     */
    @Test
    fun yesterdayIsStillYesterdayAcrossADaylightSavingChange() {
        val sydney = TimeZone.getTimeZone("Australia/Sydney")
        val calendar = Calendar.getInstance(sydney, Locale.ROOT)
        calendar.clear()
        calendar.set(2026, Calendar.OCTOBER, 4, 12, 0, 0)
        assertEquals("Yesterday", StatsFormat.dayLabel("2026-10-03", calendar.timeInMillis, en, sydney))
        assertEquals("Today", StatsFormat.dayLabel("2026-10-04", calendar.timeInMillis, en, sydney))
    }

    @Test
    fun anUnreadableKeyIsShownVerbatimRatherThanAsAWrongDate() {
        val now = at(2026, 9, 8)
        assertEquals("nonsense", StatsFormat.dayLabel("nonsense", now, en, utc))
        assertEquals("2026-13-40", StatsFormat.dayLabel("2026-13-40", now, en, utc))
    }

    @Test
    fun recentDaysAreNewestFirst() {
        val stats = UsageStats(
            dailyWords = mapOf("2026-09-06" to 1, "2026-09-08" to 3, "2026-09-07" to 2),
        )
        assertEquals(
            listOf("2026-09-08" to 3, "2026-09-07" to 2, "2026-09-06" to 1),
            StatsFormat.recentDays(stats),
        )
    }
}
