package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.core.UsageStats
import org.junit.Assert.assertTrue
import org.junit.Test

class StatsCopyTest {

    @Test
    fun resettingSaysItIsPermanentAndThatTranscriptsSurvive() {
        assertTrue(StatsCopy.RESET_BODY.contains("permanently"))
        assertTrue(StatsCopy.RESET_BODY.contains("transcripts are not affected"))
    }

    /**
     * Words per minute of recorded audio, pauses included. The honest label is
     * the mitigation for a number that would otherwise read as effort.
     */
    @Test
    fun speedIsLabelledAsSpeakingSpeed() {
        assertTrue(StatsCopy.SPEED_CAPTION.contains("Speaking Speed"))
    }

    @Test
    fun theEmptyStateNamesWhatWillAppearAndWhy() {
        assertTrue(StatsCopy.EMPTY.contains("after your first dictation"))
    }

    @Test
    fun theSettingsRowDescribesTheFeatureBeforeThereAreAnyNumbers() {
        val supporting = StatsCopy.menuSupporting(UsageStats())
        assertTrue(supporting.contains("speaking speed"))
        assertTrue("no zeroes before first use", !supporting.contains("0"))
    }

    @Test
    fun theSettingsRowShowsRealNumbersOnceThereAreSome() {
        val stats = UsageStats(
            totalWords = 7_968,
            totalTranscriptions = 541,
            currentStreak = 11,
        )
        val supporting = StatsCopy.menuSupporting(stats)
        assertTrue(supporting.contains("7,968") || supporting.contains("7968"))
        assertTrue(supporting.contains("11 days"))
    }
}
