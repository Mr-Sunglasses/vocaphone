package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Snippet triggers match after styling, but their literal expansions are
 * protected from the subsequent number conversion and restored last.
 */
class SnippetExpansionIntegrationTest {

    @Test
    fun `formal capitalization does not clobber a snippet's literal expansion`() {
        val snippets = listOf(Snippet("1", "brb", "be right back"))

        val expanded = DictatedTranscript.finished(
            "brb getting coffee",
            style = WritingStyle.FORMAL,
            repairSpeech = false,
            snippets = snippets,
        )
        // Matching is case-insensitive, so "Brb" still triggers, and the
        // expansion is inserted exactly as written rather than capitalized.
        assertEquals("be right back getting coffee.", expanded)
    }

    @Test
    fun `an email trigger does not come out capitalized`() {
        val snippets = listOf(Snippet("1", "my email", "kanishk@example.com"))

        val expanded = DictatedTranscript.finished(
            "my email is on the form",
            style = WritingStyle.FORMAL,
            repairSpeech = false,
            snippets = snippets,
        )
        assertEquals("kanishk@example.com is on the form.", expanded)
    }

    @Test
    fun `a number-word trigger wins over digit conversion and stays literal`() {
        val snippets = listOf(Snippet("1", "six pm", "six pm on the dot"))

        assertEquals(
            "5 copies at six pm on the dot.",
            DictatedTranscript.finished(
                "five copies at six pm",
                style = WritingStyle.FORMAL,
                repairSpeech = false,
                numbersAsDigits = true,
                snippets = snippets,
            ),
        )
    }
}
