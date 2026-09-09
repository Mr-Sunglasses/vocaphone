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
            "the last-used stamp never moves backwards",
            stats.lastUsedAtMillis,
            backwards.lastUsedAtMillis,
        )
    }

    @Test
    fun theFirstDictationEverStartsAStreakOfOne() {
        assertEquals(1, UsageStats.advanceStreak(current = 0, lastUsedAtMillis = 0, now = at(2026, 9, 8)))
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

    @Test
    fun pruningKeepsTheNewestByDateNotByInsertionOrder() {
        var stats = UsageStats()
        repeat(7) { day -> stats = stats.record("word", 1_000, at(2026, 9, 10 + day)) }
        // A backdated dictation arriving last must not evict a newer day.
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
    fun dayDeltaCountsCalendarDaysNotElapsedHours() {
        val lateMonday = at(2026, 9, 7, hour = 23)
        val earlyTuesday = at(2026, 9, 8, hour = 1)
        assertEquals(1, UsageStats.dayDelta(lateMonday, earlyTuesday, utc))
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
