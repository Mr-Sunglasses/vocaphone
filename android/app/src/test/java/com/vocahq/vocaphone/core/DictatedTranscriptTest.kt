package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The order of the five steps is the whole point of the funnel, and each wrong
 * order produces text that looks like a different bug.
 */
class DictatedTranscriptTest {

    @Test
    fun `digits run after styling only when enabled`() {
        assertEquals(
            "20 people came.",
            DictatedTranscript.finished(
                "twenty people came",
                style = WritingStyle.FORMAL,
                repairSpeech = false,
                numbersAsDigits = true,
            ),
        )
        assertEquals(
            "Twenty people came.",
            DictatedTranscript.finished(
                "twenty people came",
                style = WritingStyle.FORMAL,
                repairSpeech = false,
                numbersAsDigits = false,
            ),
        )
    }

    /**
     * Sanitizing first, because a model's own annotations are not something to
     * capitalize and punctuate into looking like speech.
     */
    @Test
    fun `markers are removed before anything else`() {
        assertEquals(
            "5 copies please.",
            DictatedTranscript.finished(
                "[BLANK_AUDIO] five copies please",
                style = WritingStyle.FORMAL,
                repairSpeech = false,
                numbersAsDigits = true,
            ),
        )
    }

    /**
     * Repair before styling, because repair is what puts the sentence
     * boundaries there. Styling capitalizes and terminates *around* a boundary
     * and cannot find one that is missing.
     */
    @Test
    fun `repair happens before styling`() {
        assertEquals(
            "What time is it?",
            DictatedTranscript.finished(
                "um what time is it",
                style = WritingStyle.FORMAL,
                repairSpeech = true,
            ),
        )
        // Without repair the styler sees no question and closes the sentence
        // with the full stop it is contractually allowed to add.
        assertEquals(
            "Um what time is it.",
            DictatedTranscript.finished(
                "um what time is it",
                style = WritingStyle.FORMAL,
                repairSpeech = false,
            ),
        )
    }

    /**
     * Raw promises the model's own output, so the one stage that changes words
     * never runs for it however the preference is set.
     */
    @Test
    fun `raw is never repaired`() {
        assertEquals(
            "um so we we should ship it",
            DictatedTranscript.finished(
                "um so we we should ship it",
                style = WritingStyle.RAW,
                repairSpeech = true,
            ),
        )
    }

    /**
     * A gateway has already applied the session's writing style, so that route
     * says so and the styler never runs twice.
     */
    @Test
    fun `an already styled transcript is not styled again`() {
        assertEquals(
            "Hello there.",
            DictatedTranscript.finished(
                "Hello there.",
                style = WritingStyle.CASUAL,
                styledUpstream = true,
                repairSpeech = false,
            ),
        )
        // The same text through the local route would lose its full stop to the
        // casual style — which is exactly what must not happen twice.
        assertEquals(
            "Hello there",
            DictatedTranscript.finished(
                "Hello there.",
                style = WritingStyle.CASUAL,
                repairSpeech = false,
            ),
        )
    }

    /**
     * The gateway does not repair, so this route still does — and because the
     * text arrives cased, a sentence repair creates is cased to match.
     */
    @Test
    fun `an already styled transcript is still repaired`() {
        assertEquals(
            "We shipped it on Friday. Anyway, the tests are green",
            DictatedTranscript.finished(
                "We shipped it on Friday um anyway the tests are green",
                style = WritingStyle.CASUAL,
                styledUpstream = true,
                repairSpeech = true,
            ),
        )
    }

    @Test
    fun `nothing in means nothing out`() {
        assertTrue(
            DictatedTranscript.finished(
                null,
                style = WritingStyle.CASUAL,
                styledUpstream = true,
                repairSpeech = true,
            ).isEmpty(),
        )
        assertTrue(
            DictatedTranscript.finished(
                "   ",
                style = WritingStyle.FORMAL,
                repairSpeech = true,
            ).isEmpty(),
        )
    }

    /**
     * Emoji before digits. The table's keys are words: once "hundred" has
     * become "100" there is no key left to look up, and the trigger word would
     * be typed out.
     */
    @Test
    fun `emoji runs before digits`() {
        assertEquals(
            "That was 💯",
            DictatedTranscript.finished(
                "that was hundred emoji",
                style = WritingStyle.CASUAL,
                repairSpeech = false,
                numbersAsDigits = true,
                spokenEmoji = true,
            ),
        )
    }

    /**
     * Emoji after styling, so the styler still sees "emoji" as an ordinary word
     * and closes the sentence around it. The mark it added survives the
     * substitution because only the words are replaced.
     */
    @Test
    fun `styling runs before emoji`() {
        assertEquals(
            "I'm so sad 😭",
            DictatedTranscript.finished(
                "i'm so sad crying emoji",
                style = WritingStyle.FORMAL,
                repairSpeech = false,
                spokenEmoji = true,
            ),
        )
    }

    /**
     * Raw promises the model's own output, and a glyph is not a word the model
     * returned — so this stage is skipped for it exactly as repair is.
     */
    @Test
    fun `raw never gets spoken emoji`() {
        assertEquals(
            "i'm so sad crying emoji",
            DictatedTranscript.finished(
                "i'm so sad crying emoji",
                style = WritingStyle.RAW,
                repairSpeech = true,
                spokenEmoji = true,
            ),
        )
    }

    /** The switch is what makes the stage honest: off, the words are typed out. */
    @Test
    fun `spoken emoji can be turned off`() {
        assertEquals(
            "I'm so sad crying emoji",
            DictatedTranscript.finished(
                "i'm so sad crying emoji",
                style = WritingStyle.CASUAL,
                repairSpeech = false,
                spokenEmoji = false,
            ),
        )
    }

    /**
     * Three of the same emoji dictated in a row survive the two stages that
     * collapse repetition before this one gets to see it.
     *
     * The sanitizer treats a phrase said three times as a model stuck in a
     * loop, and repair treats it as a false start. Both are right about
     * ordinary speech and both were wrong here — and because they run at stages
     * 1 and 2, the emoji stage never saw the copies to convert them. Tested
     * through the funnel because that is the only place it goes wrong.
     */
    @Test
    fun `repeated emoji survive the stages that collapse repetition`() {
        for (repair in listOf(true, false)) {
            assertEquals(
                "😭 😭 😭",
                DictatedTranscript.finished(
                    "crying emoji crying emoji crying emoji",
                    style = WritingStyle.FORMAL,
                    repairSpeech = repair,
                    spokenEmoji = true,
                ),
            )
            // Four, and with the commas a speech model writes the pauses down as.
            assertEquals(
                "🔥 🔥 🔥 🔥",
                DictatedTranscript.finished(
                    "fire emoji, fire emoji, fire emoji, fire emoji",
                    style = WritingStyle.FORMAL,
                    repairSpeech = repair,
                    spokenEmoji = true,
                ),
            )
        }
    }

    /** The exemption above must not disarm the loop protection it sits inside. */
    @Test
    fun `ordinary repetition still collapses`() {
        assertEquals(
            "Thank you.",
            DictatedTranscript.finished(
                "thank you thank you thank you thank you",
                style = WritingStyle.FORMAL,
                repairSpeech = false,
                spokenEmoji = true,
            ),
        )
    }
}
