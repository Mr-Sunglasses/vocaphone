package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Snippet expansion runs on [DictatedTranscript.finished]'s output, never on
 * its input: the writing style capitalizes sentence starts, and if expansion
 * ran first its literal text would be capitalized right along with it. This
 * mirrors the order [com.vocahq.vocaphone.dictation.DictationController.deliver]
 * uses.
 */
class SnippetExpansionIntegrationTest {

    @Test
    fun `formal capitalization does not clobber a snippet's literal expansion`() {
        val snippets = listOf(Snippet("1", "brb", "be right back"))

        val formatted = DictatedTranscript.finished(
            "brb getting coffee",
            style = WritingStyle.FORMAL,
            repairSpeech = false,
        )
        // The styler capitalized the sentence start, including the trigger.
        assertEquals("Brb getting coffee.", formatted)

        val expanded = SnippetExpander.expand(formatted, snippets)
        // Matching is case-insensitive, so "Brb" still triggers, and the
        // expansion is inserted exactly as written rather than capitalized.
        assertEquals("be right back getting coffee.", expanded)
    }

    @Test
    fun `an email trigger does not come out capitalized`() {
        val snippets = listOf(Snippet("1", "my email", "kanishk@example.com"))

        val formatted = DictatedTranscript.finished(
            "my email is on the form",
            style = WritingStyle.FORMAL,
            repairSpeech = false,
        )
        assertEquals("My email is on the form.", formatted)

        val expanded = SnippetExpander.expand(formatted, snippets)
        assertEquals("kanishk@example.com is on the form.", expanded)
    }
}
