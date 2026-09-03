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
     * The spoken forms added to `tools/emoji-suggestion-overrides.tsv` when
     * this shipped. The generated names cover most of the catalog, but these
     * are how people say them out loud, and without them the table answered
     * with the words instead of the glyph.
     */
    @Test
    fun `spoken phrasings resolve`() {
        assertEquals("😍", SpokenEmoji.glyphsIn("heart eyes emoji"))
        assertEquals("🙏", SpokenEmoji.glyphsIn("praying hands emoji"))
        assertEquals("😂", SpokenEmoji.glyphsIn("tears of joy emoji"))
        assertEquals("✅", SpokenEmoji.glyphsIn("check mark emoji"))
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
     * Three emoji dictated in a row: the pauses arrive as commas, and
     * substituting each phrase in place would leave them stranded between the
     * glyphs. A run of emoji is a run, not a list.
     */
    @Test
    fun `punctuation between two glyphs collapses`() {
        assertEquals(
            "😭 😭 😭",
            SpokenEmoji.glyphsIn("Crying emoji, crying emoji, crying emoji."),
        )
        // A longer pause is written down as a full stop, and "😭. 😭." is no
        // more something a person types than "😭, 😭".
        assertEquals("😭 🔥", SpokenEmoji.glyphsIn("Crying emoji. Fire emoji."))
        // Already a plain space: nothing to collapse, nothing changed.
        assertEquals("😭 😭", SpokenEmoji.glyphsIn("crying emoji crying emoji"))
    }

    /**
     * The collapse must not reach past the run. Punctuation that belongs to the
     * sentence around the emoji stays exactly where the styler put it.
     */
    @Test
    fun `punctuation outside the run is untouched`() {
        assertEquals("🔥, then home", SpokenEmoji.glyphsIn("fire emoji, then home"))
        assertEquals(
            "I'm sad 😭, but 🔥, then home",
            SpokenEmoji.glyphsIn("I'm sad crying emoji, but fire emoji, then home"),
        )
        // Words between two glyphs are not punctuation, so nothing collapses.
        assertEquals("😭 and 🔥", SpokenEmoji.glyphsIn("crying emoji and fire emoji"))
    }

    /**
     * A partial match must never leave the rest of what was said in front of
     * the glyph. "face with tears of joy emoji" resolving only its "joy" suffix
     * would type "face with 😂", which is worse than not converting at all — so
     * the whole phrase is a key and the longest-match rule takes it.
     */
    @Test
    fun `longer phrases do not strand their leading words`() {
        assertEquals("💯", SpokenEmoji.glyphsIn("one hundred emoji"))
        assertEquals("😂", SpokenEmoji.glyphsIn("face with tears of joy emoji"))
        assertEquals("🤣", SpokenEmoji.glyphsIn("rolling on the floor laughing emoji"))
        assertEquals("😢", SpokenEmoji.glyphsIn("crying face emoji"))
        assertEquals("👍", SpokenEmoji.glyphsIn("thumbs up sign emoji"))
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
        assertEquals("That was fun 🎉!", SpokenEmoji.glyphsIn("That was fun party emoji!"))
        assertEquals("🔥, then home", SpokenEmoji.glyphsIn("fire emoji, then home"))
        assertEquals("😭. That was rough.", SpokenEmoji.glyphsIn("Crying emoji. That was rough."))
    }

    /**
     * The styler ended the sentence while the last word was still "emoji". An
     * emoji is the end: nobody writes "I'm so sad 😭." or "💯."
     */
    @Test
    fun `a trailing terminator after a glyph goes`() {
        assertEquals("I'm so sad 😭", SpokenEmoji.glyphsIn("I'm so sad crying emoji."))
        assertEquals("💯", SpokenEmoji.glyphsIn("Hundred emoji."))
        // Only when the terminator is the whole tail — this one is ending a
        // sentence the glyph merely started.
        assertEquals("😭 is how I feel.", SpokenEmoji.glyphsIn("Crying emoji is how I feel."))
    }

    /**
     * A full stop is structure and goes; "!" and "?" carry meaning that was in
     * what the user said, exactly as the casual writing style already argues.
     */
    @Test
    fun `meaningful terminators after a glyph stay`() {
        assertEquals("😭!", SpokenEmoji.glyphsIn("Crying emoji!"))
        assertEquals("😭?", SpokenEmoji.glyphsIn("Crying emoji?"))
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

    /**
     * The single-character pre-check must be invisible. It skips text with no
     * "j" in it, so the cases that matter are the ones that still have to work
     * after passing it — and the ones it correctly lets through.
     */
    @Test
    fun `the fast path changes nothing`() {
        // No "j" anywhere: skipped, and identical either way.
        val untouched = "no trigger anywhere in this sentence at all"
        assertEquals(untouched, SpokenEmoji.glyphsIn(untouched))
        // A "j" from an ordinary word, no trigger: falls through to the full
        // walk, which declines it.
        assertEquals("just a jar of jam", SpokenEmoji.glyphsIn("just a jar of jam"))
        // "emojify" carries the "j" and the substring, so the pre-check passes
        // it; the word-boundary rule is what correctly declines it.
        assertEquals("fire emojify", SpokenEmoji.glyphsIn("fire emojify"))
        // Upper case has to survive the fold, or a shouted trigger is lost.
        assertEquals("🔥 now", SpokenEmoji.glyphsIn("Fire EMOJI now"))
    }
}
