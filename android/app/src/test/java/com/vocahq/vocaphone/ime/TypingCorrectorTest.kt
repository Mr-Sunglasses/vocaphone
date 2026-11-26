package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.Snippet
import com.vocahq.vocaphone.settings.BlockedSuggestions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TypingCorrectorTest {

    private val ready = SuggestionStrip(listOf("the", "tea"), autocorrection = "the", forWord = "teh")

    private fun correction(
        typed: String,
        boundary: String = " ",
        learned: String? = null,
        strip: SuggestionStrip = ready,
        autocorrect: Boolean = true,
        asserted: Set<String> = emptySet(),
    ) = TypingCorrector.correction(typed, boundary, learned, strip, autocorrect, asserted)

    @Test
    fun `space and sentence punctuation end a word, other keys do not`() {
        assertEquals(" ", TypingCorrector.boundary(KeyboardKey("space", "space", type = KeyboardKeyType.SPACE)))
        for (mark in listOf(".", ",", "!", "?", ";", ":", "'")) {
            assertEquals(mark, TypingCorrector.boundary(KeyboardKey("c-$mark", mark)))
        }
        assertNull(TypingCorrector.boundary(KeyboardKey("c-a", "a")))
        assertNull(TypingCorrector.boundary(KeyboardKey("c-@", "@")))
        assertNull(TypingCorrector.boundary(KeyboardKey("return", "Enter", type = KeyboardKeyType.RETURN)))
    }

    @Test
    fun `the strip's fix applies only to the word it was worked out for`() {
        assertEquals("the", correction("teh"))
        assertEquals("the", correction("teh", boundary = ","))
        assertNull(correction("tehh"))
        // Worked out, and no fix: the word stands.
        assertNull(correction("teh", strip = SuggestionStrip(listOf("tea"), forWord = "teh")))
    }

    @Test
    fun `a learned fix comes before the strip's`() {
        assertEquals("tea", correction("teh", learned = "tea"))
        assertNull(correction("teh", autocorrect = false))
    }

    @Test
    fun `a learned fix is gated like any other correction`() {
        // Corrections off, or a field that takes none (an address, a link).
        assertNull(correction("teh", learned = "tea", autocorrect = false))
        // Put back in this field: it stays put back.
        assertNull(correction("teh", learned = "tea", asserted = setOf("teh")))
        // An abbreviation before its period is typed on purpose.
        assertNull(correction("etc", boundary = ".", learned = "etch"))
        assertEquals("etch", correction("etc", boundary = ",", learned = "etch"))
    }

    @Test
    fun `a word put back here, or an abbreviation before a period, stands`() {
        assertNull(correction("teh", asserted = setOf("teh")))
        val strip = SuggestionStrip(emptyList(), autocorrection = "etch", forWord = "etc")
        assertNull(correction("etc", boundary = ".", strip = strip))
        assertEquals("etch", correction("etc", boundary = ",", strip = strip))
    }

    @Test
    fun `a stale strip still capitalises i, and nothing else`() {
        val stale = SuggestionStrip(listOf("in"), forWord = "")
        assertEquals("I", correction("i", strip = stale))
        assertEquals("I'm", correction("im", strip = stale))
        assertNull(correction("teh", strip = stale))
        assertNull(correction("i", strip = stale, autocorrect = false))
        assertEquals("I", correction("i", boundary = "'", strip = stale))
        assertNull(correction("im", boundary = "'", strip = stale))
    }

    @Test
    fun `delete takes the fix and its boundary back, a chip keeps the boundary`() {
        val undo = AutocorrectUndo(typed = "teh", fixed = "the", boundary = ".", alternatives = listOf("the", "tea", "ten"))
        assertEquals(KeyboardCommand.ReplaceBeforeCursor(4, "teh"), undo.deleteCommand())
        assertEquals(KeyboardCommand.ReplaceBeforeCursor(4, "tea."), undo.replaceCommand("tea"))
        assertEquals(
            listOf(
                SuggestionItem("teh", kind = SuggestionKind.REVERT),
                SuggestionItem("tea", kind = SuggestionKind.REPLACE_FIX),
                SuggestionItem("ten", kind = SuggestionKind.REPLACE_FIX),
            ),
            undo.strip,
        )
        assertEquals(listOf(undo.replaceCommand("teh")), TypingAssist.pick(undo.strip.first(), undo, ""))
        assertEquals(listOf(undo.replaceCommand("tea")), TypingAssist.pick(undo.strip[1], undo, ""))
    }

    @Test
    fun `put-back words are remembered for the field until it changes`() {
        val corrector = TypingCorrector()
        corrector.assert("Teh")
        assertEquals(setOf("teh"), corrector.asserted)
        val version = corrector.assertedVersion
        corrector.forget()
        assertEquals(setOf("teh"), corrector.asserted)
        corrector.reset()
        assertTrue(corrector.asserted.isEmpty())
        assertTrue(corrector.assertedVersion > version)
    }

    @Test
    fun `a fix held across a layer switch applies to the punctuation after it`() {
        val corrector = TypingCorrector()
        corrector.hold("teh", "the")
        assertEquals("teh" to "the", corrector.takeHeld("?"))
        assertNull(corrector.takeHeld("?"))
        corrector.hold("teh", "the")
        assertNull(corrector.takeHeld(null))
        assertNull(corrector.takeHeld("!"))
        corrector.hold("teh", "the")
        assertNull(corrector.takeHeld(" "))
        corrector.hold("the", "the")
        assertNull(corrector.takeHeld("?"))
    }

    @Test
    fun `snippet and sum chips edit the field`() {
        val snippet = SuggestionItem("on my way", kind = SuggestionKind.SNIPPET, replaces = "omw")
        assertEquals(listOf(KeyboardCommand.ReplaceBeforeCursor(3, "on my way ")), TypingAssist.pick(snippet, null, ""))
        assertEquals(listOf(KeyboardCommand.ReplaceBeforeCursor(3, "on my way")), TypingAssist.pick(snippet, null, " later"))
        assertEquals(listOf(KeyboardCommand.CommitText("48")), TypingAssist.pick(SuggestionItem("48", kind = SuggestionKind.RESULT), null, ""))
        assertNull(TypingAssist.pick(SuggestionItem("word"), null, ""))
        assertNull(TypingAssist.pick(SuggestionItem("teh", kind = SuggestionKind.KEEP_TYPED), null, ""))
    }

    @Test
    fun `strip items lead with chips, keep the typed word beside a correction`() {
        val strip = SuggestionStrip(
            words = listOf("the", "tea"),
            autocorrection = "the",
            forWord = "teh",
            keepTyped = "teh",
            extras = listOf(SuggestionItem("48", kind = SuggestionKind.RESULT)),
        )
        assertEquals(
            listOf(SuggestionKind.RESULT, SuggestionKind.KEEP_TYPED, SuggestionKind.AUTOCORRECT, SuggestionKind.WORD),
            strip.items.map { it.kind },
        )
        val blocked = strip.without("The")
        assertNull(blocked.autocorrection)
        assertNull(blocked.keepTyped)
        assertEquals(listOf("tea"), blocked.words)
        assertTrue(SuggestionKind.AUTOCORRECT.blockable)
        assertFalse(SuggestionKind.REVERT.blockable)
        assertFalse(SuggestionKind.SNIPPET.blockable)
    }

    @Test
    fun `labels and TalkBack say what a chip does`() {
        assertEquals("“teh”", suggestionLabel(SuggestionItem("teh", kind = SuggestionKind.REVERT)))
        assertEquals("Restore teh", suggestionDescription(SuggestionItem("teh", kind = SuggestionKind.REVERT)))
        assertEquals("= 48", suggestionLabel(SuggestionItem("48", kind = SuggestionKind.RESULT)))
        assertEquals("a b", suggestionLabel(SuggestionItem("a\nb", kind = SuggestionKind.SNIPPET)))
        assertEquals("+ word", suggestionLabel(SuggestionItem("word", savesWord = true)))
    }

    @Test
    fun `typed snippet triggers are offered as chips`() {
        val snippets = listOf(
            Snippet("1", "omw", "On my way!"),
            Snippet("2", "my email", "me@example.com"),
            Snippet("3", "email", "short"),
            Snippet("4", "blank", " "),
        )
        assertEquals("On my way!", TypingChips.extras("see you ", "omw", snippets).single().text)
        assertEquals("omw", TypingChips.extras("see you ", "omw", snippets).single().replaces)
        // The longer trigger wins, and replaces both words.
        val email = TypingChips.extras("send it to my ", "email", snippets).single()
        assertEquals("me@example.com", email.text)
        assertEquals("my email", email.replaces)
        // Not inside a longer word, not after a space, not a blank expansion.
        assertTrue(TypingChips.extras("", "xomw", snippets).isEmpty())
        assertTrue(TypingChips.extras("omw ", "", snippets).isEmpty())
        assertTrue(TypingChips.extras("", "blank", snippets).isEmpty())
        // Case-insensitive, as dictation matches.
        assertEquals("On my way!", TypedSnippets.match("OMW", snippets)?.second?.expansion)
    }

    @Test
    fun `blocked words are stored lowercase, newest first, and counted`() {
        val one = BlockedSuggestions.add("", "Hello")
        val two = BlockedSuggestions.add(one, "world")
        assertEquals("world, hello", BlockedSuggestions.add(two, "HELLO").let { BlockedSuggestions.add(it, "world") })
        assertEquals(2, BlockedSuggestions.count(two))
        assertEquals(setOf("hello", "world"), BlockedSuggestions.words(two))
        assertEquals(0, BlockedSuggestions.count(null))
        val dictionary = SuggestionDictionary(listOf("hello", "help"), emptyMap())
        assertFalse(dictionary.allows("Hello", null, false, setOf("hello"), blocked = setOf("hello")))
        assertTrue(dictionary.allows("help", null, false, emptySet(), blocked = setOf("hello")))
        assertEquals(listOf("help"), dictionary.strip("hel", "", "", true, options = StripOptions(blocked = setOf("hello"))).words)
    }
}
