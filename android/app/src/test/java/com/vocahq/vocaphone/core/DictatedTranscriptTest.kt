package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The order of the four steps is the whole point of the funnel, and each wrong
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
}
