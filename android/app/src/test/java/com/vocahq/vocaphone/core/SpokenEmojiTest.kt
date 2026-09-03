package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rules that stop "emoji" being eaten out of ordinary sentences. Each one
 * exists because the obvious implementation gets it wrong.
 *
 * Mirrors `ios/VocaPhoneTests/SpokenEmojiTests.swift` case for case: the two
 * ports read the same generated table and are expected to agree.
 */
class SpokenEmojiTest {
    @Test
    fun `a descriptor and the trigger become the glyph`() {
        assertEquals("I'm so sad 😭", SpokenEmoji.glyphsIn("I'm so sad crying emoji"))
    }

    /**
     * The worked example from the plan, and the case that proves repeats need
     * no special handling: two triggers are two independent matches.
     */
    @Test
    fun `repeated triggers each convert`() {
        assertEquals(
            "I'm so sad 😭 😭",
            SpokenEmoji.glyphsIn("I'm so sad crying emoji crying emoji"),
        )
    }

    /**
     * Keys are the descriptor with its spaces removed, so a multi-word
     * descriptor resolves without the table having to store the spacing.
     */
    @Test
    fun `multi-word descriptors resolve`() {
        assertEquals("nice work 👍", SpokenEmoji.glyphsIn("nice work thumbs up emoji"))
        assertEquals("🤷", SpokenEmoji.glyphsIn("shrug emoji"))
    }

    /**
     * The longest phrase wins. "loudly crying" and "crying" are both keys, and
     * stopping at the first match would leave the word "loudly" behind.
     */
    @Test
    fun `the longest phrase wins`() {
        assertEquals("😭", SpokenEmoji.glyphsIn("loudly crying emoji"))
    }

    /**
     * A trigger with nothing it recognizes in front of it is left exactly as
     * spoken. This is the case the feature is judged on: it must never guess.
     */
    @Test
    fun `an unmatched trigger is left alone`() {
        assertEquals("Send me the emoji.", SpokenEmoji.glyphsIn("Send me the emoji."))
        assertEquals("emoji", SpokenEmoji.glyphsIn("emoji"))
        // "emoji" is not itself a key, so a trigger cannot match its neighbour.
        assertEquals("emoji emoji", SpokenEmoji.glyphsIn("emoji emoji"))
    }

    @Test
    fun `the trigger may be pluralized`() {
        assertEquals("add 🔥", SpokenEmoji.glyphsIn("add fire emojis"))
    }

    /**
     * Styling has already run, so the trigger arrives carrying whatever mark
     * the style put on it. Only the words are replaced, which leaves the mark
     * and the spacing exactly where the styler left them.
     */
    @Test
    fun `punctuation the styler attached survives`() {
        assertEquals("I'm so sad 😭.", SpokenEmoji.glyphsIn("I'm so sad crying emoji."))
        assertEquals("That was fun 🎉!", SpokenEmoji.glyphsIn("That was fun party emoji!"))
        assertEquals("🔥, then home", SpokenEmoji.glyphsIn("fire emoji, then home"))
    }

    /**
     * FORMAL capitalizes a sentence start, so a descriptor can arrive
     * capitalized. Matching is case-insensitive.
     */
    @Test
    fun `a capitalized descriptor still matches`() {
        assertEquals("😭. That was rough.", SpokenEmoji.glyphsIn("Crying emoji. That was rough."))
    }

    /**
     * Only a space or a hyphen joins a descriptor to its trigger. A comma is a
     * clause boundary, and reading through it would take a word out of the
     * sentence before.
     */
    @Test
    fun `punctuation inside the phrase ends it`() {
        assertEquals("I was crying, emoji", SpokenEmoji.glyphsIn("I was crying, emoji"))
    }

    /**
     * Masked before the walk, so a descriptor cannot be taken out of an
     * address. The dot makes this a hostname, not a trigger.
     */
    @Test
    fun `addresses are not eaten`() {
        assertEquals("see crying emoji.com", SpokenEmoji.glyphsIn("see crying emoji.com"))
        assertEquals(
            "mail fire emoji@example.com",
            SpokenEmoji.glyphsIn("mail fire emoji@example.com"),
        )
    }

    /**
     * Nothing about a transcript in another script matches an English table,
     * which is the whole language policy: untouched beats partially mangled.
     */
    @Test
    fun `other languages pass through`() {
        assertEquals("मैं बहुत खुश हूँ।", SpokenEmoji.glyphsIn("मैं बहुत खुश हूँ।"))
    }

    @Test
    fun `text with no trigger is returned unchanged`() {
        assertEquals("just an ordinary sentence", SpokenEmoji.glyphsIn("just an ordinary sentence"))
        assertEquals("", SpokenEmoji.glyphsIn(""))
    }

    /**
     * The lookback is bounded by the table's own widest key rather than a
     * guessed word count, so the bound cannot drift from the data.
     */
    @Test
    fun `the table supplies its own lookback bound`() {
        assertTrue(EmojiTable.widestKeyLength > 0)
        assertEquals("😭", EmojiTable.triggers["loudlycrying"])
        assertNull(EmojiTable.triggers["emoji"])
    }
}
