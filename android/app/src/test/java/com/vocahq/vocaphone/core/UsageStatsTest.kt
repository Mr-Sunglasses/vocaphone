package com.vocahq.vocaphone.core

import java.util.Calendar
import java.util.Locale
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class UsageStatsTest {

    private val utc = TimeZone.getTimeZone("UTC")
    private lateinit var previousZone: TimeZone

    /**
     * Day keys and streaks are deliberately local-calendar, so the fixtures and
     * the code under test have to agree on which calendar. Without this the
     * suite passes or fails depending on where it is run: two timestamps twelve
     * hours apart on one UTC day fall on two different days in Asia/Kolkata.
     */
    @Before
    fun useAFixedZone() {
        previousZone = TimeZone.getDefault()
        TimeZone.setDefault(utc)
    }

    @After
    fun restoreZone() {
        TimeZone.setDefault(previousZone)
    }

    private fun at(year: Int, month: Int, day: Int, hour: Int = 12): Long {
        val calendar = Calendar.getInstance(utc, Locale.ROOT)
        calendar.clear()
        calendar.set(year, month - 1, day, hour, 0, 0)
        return calendar.timeInMillis
    }

    // --- word counting -----------------------------------------------------

    @Test
    fun countsEnglishWords() {
        assertEquals(7, UsageStats.wordCount("Meet me by the station at six"))
    }

    @Test
    fun ignoresSurroundingWhitespaceAndPunctuationOnlySegments() {
        assertEquals(2, UsageStats.wordCount("  hello, world!  "))
        assertEquals(0, UsageStats.wordCount("!!! ... ???"))
        assertEquals(0, UsageStats.wordCount("   "))
        assertEquals(0, UsageStats.wordCount(""))
    }

    @Test
    fun countsDigitsAndContractionsAsWords() {
        assertEquals(3, UsageStats.wordCount("it's 42 degrees"))
    }

    /**
     * Segmentation quality for a space-less script belongs to the platform's
     * tokenizer, and the two platforms differ: on a device this is ICU with its
     * Chinese and Thai dictionaries, while the desktop JVM running this suite
     * has neither and returns one word for a whole Han sentence. Asserting a
     * count here would either encode the JVM's answer as if it were the
     * product's, or fail on a machine whose JDK ships different data.
     *
     * So this asserts only what holds on both: text in a space-less script is
     * counted, mixed script is not truncated at the boundary, and nothing throws.
     * The device behaviour is covered by the manual pass instead.
     */
    @Test
    fun handlesSpacelessScriptsWithoutFailingOrReturningZero() {
        assertTrue(UsageStats.wordCount("这是一个测试句子") >= 1)
        assertTrue(UsageStats.wordCount("これはテストです") >= 1)
        assertTrue(UsageStats.wordCount("นี่คือการทดสอบ") >= 1)
    }

    @Test
    fun countsBothHalvesOfAMixedScriptTranscript() {
        val mixed = UsageStats.wordCount("hello 世界 world")
        assertTrue("the Latin words alone are two", mixed > 2)
    }

    @Test
    fun emojiOnlyTranscriptCountsNoWords() {
        assertEquals(0, UsageStats.wordCount("😭😭"))
    }

    // --- recording ---------------------------------------------------------

    @Test
    fun oneDictationIncrementsEveryTotalExactlyOnce() {
        val stats = UsageStats().record("hello world", 5_000, at(2026, 9, 8))
        assertEquals(2, stats.totalWords)
        assertEquals(1, stats.totalTranscriptions)
        assertEquals(5_000, stats.totalAudioMillis)
        assertEquals(1, stats.currentStreak)
        assertEquals(1, stats.bestStreak)
    }

    @Test
    fun anEmptyTranscriptIsNotADictation() {
        val before = UsageStats().record("hello", 1_000, at(2026, 9, 8))
        assertEquals(before, before.record("   ", 9_000, at(2026, 9, 8)))
        assertEquals(before, before.record("", 9_000, at(2026, 9, 8)))
    }

    @Test
    fun anUnknownDurationStillCountsItsWords() {
        val stats = UsageStats().record("hello world", null, at(2026, 9, 8))
        assertEquals(2, stats.totalWords)
        assertEquals(1, stats.totalTranscriptions)
        assertEquals(0, stats.totalAudioMillis)
    }

    @Test
    fun speakingSpeedIsWordsPerMinuteOfAudioAndSurvivesZeroDuration() {
        assertEquals(0.0, UsageStats().averageWordsPerMinute, 0.0001)
        val stats = UsageStats(totalWords = 120, totalAudioMillis = 60_000)
        assertEquals(120.0, stats.averageWordsPerMinute, 0.0001)
    }

    // --- streaks -----------------------------------------------------------

    @Test
    fun twoDictationsOnTheSameDayAreOneStreakDay() {
        val stats = UsageStats()
            .record("one two", 1_000, at(2026, 9, 8, hour = 9))
            .record("three four", 1_000, at(2026, 9, 8, hour = 21))
        assertEquals(1, stats.currentStreak)
        assertEquals(4, stats.totalWords)
        assertEquals(2, stats.totalTranscriptions)
    }

    @Test
    fun consecutiveDaysExtendTheStreakAndAGapResetsIt() {
        var stats = UsageStats()
        repeat(3) { day -> stats = stats.record("word", 1_000, at(2026, 9, 1 + day)) }
        assertEquals(3, stats.currentStreak)
        assertEquals(3, stats.bestStreak)

        stats = stats.record("word", 1_000, at(2026, 9, 10))
        assertEquals(1, stats.currentStreak)
        assertEquals("the best is a high-water mark", 3, stats.bestStreak)
    }

    /**
     * VocaMac resets the streak for any delta that is not 0 or 1, so a clock
     * moved backwards or a flight west across midnight kills a long run. It must
     * not do that here.
     */
    @Test
    fun aBackwardsClockDoesNotBreakTheStreak() {
        var stats = UsageStats()
        repeat(5) { day -> stats = stats.record("word", 1_000, at(2026, 9, 1 + day)) }
        assertEquals(5, stats.currentStreak)

        val backwards = stats.record("word", 1_000, at(2026, 9, 3))
        assertEquals(5, backwards.currentStreak)
        assertEquals(
            "the last day never moves backwards",
            stats.lastDayKey,
            backwards.lastDayKey,
        )
    }

    @Test
    fun theFirstDictationEverStartsAStreakOfOne() {
        assertEquals(
            1,
            UsageStats.advanceStreak(current = 0, lastDayKey = "", todayKey = "2026-09-08"),
        )
    }

    // --- pruning -----------------------------------------------------------

    @Test
    fun onlyTheSevenMostRecentDaysAreKept() {
        var stats = UsageStats()
        repeat(8) { day -> stats = stats.record("word", 1_000, at(2026, 9, 1 + day)) }

        assertEquals(UsageStats.DAILY_LIMIT, stats.dailyWords.size)
        assertEquals("the oldest day is dropped", null, stats.dailyWords["2026-09-01"])
        assertTrue(stats.dailyWords.containsKey("2026-09-08"))
        assertEquals("totals are never pruned", 8, stats.totalTranscriptions)
        assertEquals(8, stats.totalWords)
    }

    /**
     * DIAGNOSTIC (expected to fail): pruning sorts keys lexicographically, and an
     * unreadable label sorts above every real date. With the window full, the bad
     * key survives and the oldest genuine day is evicted — so a damaged label
     * costs a real day's word count, which is the outcome leaving the day map
     * unvalidated was meant to avoid.
     */
    @Test
    fun anUnreadableDayLabelDoesNotEvictARealDay() {
        val poisoned = buildMap {
            repeat(UsageStats.DAILY_LIMIT) { day ->
                put(UsageStats.dayKey(at(2026, 9, 1 + day), utc), 10)
            }
            put("zzz-bad-key", 99)
        }

        val pruned = UsageStats.pruneDaily(poisoned)

        assertEquals(UsageStats.DAILY_LIMIT, pruned.size)
        assertEquals("a real day outranks an unreadable one", false, pruned.containsKey("zzz-bad-key"))
        assertTrue("the oldest real day survives", pruned.containsKey("2026-09-01"))
    }

    @Test
    fun pruningKeepsTheNewestByDateNotByInsertionOrder() {
        var stats = UsageStats()
        repeat(7) { day -> stats = stats.record("word", 1_000, at(2026, 9, 10 + day)) }
        stats = stats.record("word", 1_000, at(2026, 9, 1))

        assertEquals(UsageStats.DAILY_LIMIT, stats.dailyWords.size)
        assertEquals(null, stats.dailyWords["2026-09-01"])
        assertTrue(stats.dailyWords.containsKey("2026-09-16"))
    }

    /**
     * The regression test for storing streaks rather than deriving them: seven
     * retained days cannot describe a ten-day run.
     */
    @Test
    fun aStreakLongerThanTheDailyWindowSurvivesPruning() {
        var stats = UsageStats()
        repeat(10) { day -> stats = stats.record("word", 1_000, at(2026, 9, 1 + day)) }
        assertEquals(10, stats.currentStreak)
        assertEquals(UsageStats.DAILY_LIMIT, stats.dailyWords.size)
    }

    // --- day keys ----------------------------------------------------------

    @Test
    fun dayKeysAreSortableGregorianDatesWhateverTheDefaultLocale() {
        val previous = Locale.getDefault()
        try {
            // A Thai default locale writes Buddhist years through the usual
            // formatters, which would neither sort nor match yesterday's keys.
            Locale.setDefault(Locale.forLanguageTag("th-TH-u-ca-buddhist-nu-thai"))
            assertEquals("2026-09-08", UsageStats.dayKey(at(2026, 9, 8), utc))
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test
    fun daysBetweenCountsCalendarDaysNotElapsedHours() {
        assertEquals(1, UsageStats.daysBetween("2026-09-07", "2026-09-08"))
        assertEquals(0, UsageStats.daysBetween("2026-09-08", "2026-09-08"))
        assertEquals(-1, UsageStats.daysBetween("2026-09-08", "2026-09-07"))
        assertEquals("across a month end", 1, UsageStats.daysBetween("2026-09-30", "2026-10-01"))
    }

    @Test
    fun daysBetweenReportsAnUnreadableKeyRatherThanThrowing() {
        assertEquals(null, UsageStats.daysBetween("not-a-date", "2026-09-08"))
        assertEquals(null, UsageStats.daysBetween("2026-09-08", ""))
        assertEquals(null, UsageStats.daysBetween("2026-13-40", "2026-09-08"))
    }

    // --- streak expiry -----------------------------------------------------

    /**
     * The stored streak is only ever written when a dictation is recorded, so
     * the read path has to expire it. Nothing runs in between to do it.
     */
    @Test
    fun aStreakStaysAliveWhileItIsStillExtendable() {
        var stats = UsageStats()
        repeat(5) { day -> stats = stats.record("word", 1_000, at(2026, 9, 1 + day)) }
        assertEquals("same day", 5, stats.currentStreakAt(at(2026, 9, 5, hour = 23)))
        assertEquals("the next day, still extendable", 5, stats.currentStreakAt(at(2026, 9, 6)))
    }

    @Test
    fun aStreakExpiresOnceADayHasBeenMissed() {
        var stats = UsageStats()
        repeat(5) { day -> stats = stats.record("word", 1_000, at(2026, 9, 1 + day)) }
        assertEquals("a day was missed", 0, stats.currentStreakAt(at(2026, 9, 7)))
        assertEquals(0, stats.currentStreakAt(at(2026, 10, 20)))
    }

    @Test
    fun anExpiredStreakLeavesTheBestOneAlone() {
        var stats = UsageStats()
        repeat(5) { day -> stats = stats.record("word", 1_000, at(2026, 9, 1 + day)) }
        assertEquals(0, stats.currentStreakAt(at(2026, 9, 20)))
        assertEquals("best is a high-water mark, not a current state", 5, stats.bestStreak)
    }

    @Test
    fun neverUsedReadsAsNoStreak() {
        assertEquals(0, UsageStats().currentStreakAt(at(2026, 9, 8)))
    }

    @Test
    fun anUnreadableStoredDayReadsAsNoStreakRatherThanCrashing() {
        val corrupt = UsageStats(currentStreak = 9, lastDayKey = "yesterday-ish")
        assertEquals(0, corrupt.currentStreakAt(at(2026, 9, 8)))

        val repaired = corrupt.record("word", 1_000, at(2026, 9, 8))
        assertEquals(1, repaired.currentStreak)
        assertEquals("the bad key is replaced, not kept", "2026-09-08", repaired.lastDayKey)
    }

    @Test
    fun aCorruptDayDoesNotWedgeTheStreakForever() {
        val corrupt = UsageStats(currentStreak = 9, lastDayKey = "not-a-date")

        val firstDay = corrupt.record("word", 1_000, at(2026, 9, 8))
        assertEquals(1, firstDay.currentStreak)

        val secondDay = firstDay.record("word", 1_000, at(2026, 9, 9))
        assertEquals("the run recovers instead of sticking at 1", 2, secondDay.currentStreak)
        assertEquals("2026-09-09", secondDay.lastDayKey)
    }

    /**
     * DIAGNOSTIC (expected to fail): isDayKey only asks whether a label parses,
     * and a date years ahead parses perfectly well. A device with a wrong clock —
     * a dead RTC, a manual test, bad time sync — can record one dictation dated
     * in the future. After the clock is corrected every comparison against it is
     * negative, which reads as "same day": the run never expires and never
     * advances. Same permanent freeze as a corrupt key, through a valid one.
     */
    @Test
    fun aFutureDatedDayDoesNotFreezeTheStreakForever() {
        val skewed = UsageStats(currentStreak = 4, bestStreak = 4, lastDayKey = "2099-01-01")

        assertEquals("that run is long over", 0, skewed.currentStreakAt(at(2026, 9, 9)))

        val recorded = skewed.record("word", 1_000, at(2026, 9, 9))
        assertEquals("a fresh dictation starts a new run", 1, recorded.currentStreak)
        assertEquals("2026-09-09", recorded.lastDayKey)
    }

    @Test
    fun dayKeysAreRecognisedOnlyWhenTheyCanStillBeRead() {
        assertTrue(UsageStats.isDayKey(UsageStats.dayKey(at(2026, 9, 8), utc)))
        assertTrue(UsageStats.isDayKey("2026-09-08"))
        assertEquals(false, UsageStats.isDayKey(""))
        assertEquals(false, UsageStats.isDayKey("not-a-date"))
        assertEquals(false, UsageStats.isDayKey("2026-13-40"))
        assertEquals("unpadded is not the format we write", false, UsageStats.isDayKey("2026-9-8"))
    }

    /**
     * The defect this key-based comparison exists to prevent: the streak and the
     * list underneath it must describe the same days, even when the phone moves
     * between timezones between dictations.
     */
    @Test
    fun aTimezoneChangeCannotDesynchroniseTheStreakFromRecentActivity() {
        val kolkata = TimeZone.getTimeZone("Asia/Kolkata")
        val pacific = TimeZone.getTimeZone("America/Los_Angeles")

        TimeZone.setDefault(kolkata)
        val kolkataCalendar = Calendar.getInstance(kolkata, Locale.ROOT)
        kolkataCalendar.clear()
        kolkataCalendar.set(2026, Calendar.SEPTEMBER, 9, 2, 0, 0)
        var stats = UsageStats().record("one two three", 1_000, kolkataCalendar.timeInMillis)
        assertEquals(1, stats.currentStreak)

        TimeZone.setDefault(pacific)
        val pacificCalendar = Calendar.getInstance(pacific, Locale.ROOT)
        pacificCalendar.clear()
        pacificCalendar.set(2026, Calendar.SEPTEMBER, 9, 12, 0, 0)
        stats = stats.record("four five", 1_000, pacificCalendar.timeInMillis)

        assertEquals(
            "one day recorded, so one row and one streak day",
            stats.dailyWords.size,
            stats.currentStreak,
        )
    }

    // --- encoding ----------------------------------------------------------

    @Test
    fun roundTrips() {
        val stats = UsageStats()
            .record("hello world", 5_000, at(2026, 9, 8))
            .record("again", 3_000, at(2026, 9, 9))
        assertEquals(stats, UsageStats.decode(UsageStats.encode(stats)))
    }

    @Test
    fun unreadableStorageBecomesEmptyStatsRatherThanACrash() {
        assertEquals(UsageStats(), UsageStats.decode(null))
        assertEquals(UsageStats(), UsageStats.decode(""))
        assertEquals(UsageStats(), UsageStats.decode("not json"))
        assertEquals(UsageStats(), UsageStats.decode("""{"totalWords":"""))
        assertEquals(UsageStats(), UsageStats.decode("[1,2,3]"))
    }

    @Test
    fun aPayloadMissingFieldsKeepsTheOnesItHas() {
        val stats = UsageStats.decode("""{"totalWords":42}""")
        assertEquals(42, stats.totalWords)
        assertEquals(0, stats.totalTranscriptions)
        assertEquals(emptyMap<String, Int>(), stats.dailyWords)
    }

    @Test
    fun aPayloadWithoutTheDayKeyRecoversItFromTheRetainedDays() {
        val legacy = """
            {"totalWords":40,"totalTranscriptions":4,"currentStreak":3,"bestStreak":3,
             "lastUsedAtMillis":1757376000000,
             "daily":{"2026-09-06":10,"2026-09-07":10,"2026-09-08":20}}
        """.trimIndent()
        val stats = UsageStats.decode(legacy)
        assertEquals("2026-09-08", stats.lastDayKey)
        assertEquals(3, stats.currentStreakAt(at(2026, 9, 8)))
    }

    @Test
    fun anUnreadableStoredDayKeyDecodesToNeverRatherThanBeingTrusted() {
        val stats = UsageStats.decode(
            """{"totalWords":40,"currentStreak":9,"bestStreak":9,"lastDayKey":"not-a-date"}""",
        )
        assertEquals("", stats.lastDayKey)
        assertEquals(0, stats.currentStreakAt(at(2026, 9, 8)))
        assertEquals("the totals are not collateral", 40, stats.totalWords)
    }

    @Test
    fun anUnreadableDayKeyFallsBackToTheNewestRealDay() {
        val stats = UsageStats.decode(
            """{"currentStreak":3,"lastDayKey":"???","daily":{"2026-09-07":10,"2026-09-08":20}}""",
        )
        assertEquals("2026-09-08", stats.lastDayKey)
        assertEquals(3, stats.currentStreakAt(at(2026, 9, 8)))
    }

    @Test
    fun aPoisonedDayMapCannotSupplyTheLastDay() {
        val stats = UsageStats.decode(
            """{"totalWords":40,"currentStreak":3,"daily":{"2026-09-07":10,"zzz-bad-key":20}}""",
        )
        assertEquals("the newest day it can vouch for", "2026-09-07", stats.lastDayKey)
        assertEquals("the counts themselves are kept", 40, stats.totalWords)
    }

    @Test
    fun aDayMapWithNothingReadableLeavesNoLastDay() {
        val stats = UsageStats.decode("""{"totalWords":40,"daily":{"zzz-bad-key":20}}""")
        assertEquals("", stats.lastDayKey)
        assertEquals(0, stats.currentStreakAt(at(2026, 9, 8)))
    }

    @Test
    fun aPayloadWithNeitherDayKeyNorDaysHasNoStreakToRestore() {
        val stats = UsageStats.decode("""{"totalWords":40,"currentStreak":3}""")
        assertEquals("", stats.lastDayKey)
        assertEquals(0, stats.currentStreakAt(at(2026, 9, 8)))
    }

    @Test
    fun anUnknownFieldFromANewerBuildIsIgnoredRatherThanFatal() {
        val stats = UsageStats.decode("""{"totalWords":7,"somethingNew":"x"}""")
        assertEquals(7, stats.totalWords)
    }

    /**
     * The lifetime totals are the expensive thing to lose, so a damaged day map
     * must not take them with it.
     */
    @Test
    fun aMalformedDayMapCostsTheActivityListButNotTheTotals() {
        val stats = UsageStats.decode("""{"totalWords":99,"totalTranscriptions":5,"daily":"nonsense"}""")
        assertEquals(99, stats.totalWords)
        assertEquals(5, stats.totalTranscriptions)
        assertEquals(emptyMap<String, Int>(), stats.dailyWords)
    }

    @Test
    fun negativeStoredValuesAreClampedRatherThanTrusted() {
        val stats = UsageStats.decode("""{"totalWords":-5,"currentStreak":-2}""")
        assertEquals(0, stats.totalWords)
        assertEquals(0, stats.currentStreak)
    }

    @Test
    fun emptyStatsAreDistinguishableFromUsedOnes() {
        assertEquals(false, UsageStats().hasAny)
        assertNotEquals(false, UsageStats().record("word", 1_000, at(2026, 9, 8)).hasAny)
    }
}
