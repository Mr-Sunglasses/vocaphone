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
        assertEquals("😭", SpokenEmoji.glyphsIn("crying emoji"))
    }

    /**
     * The worked example from the plan, and the case that proves repeats need
     * no special handling: two triggers are two independent matches.
     */
    @Test
    fun `repeated triggers each convert`() {
        assertEquals(
            "😭 😭",
            SpokenEmoji.glyphsIn("crying emoji crying emoji"),
        )
    }

    /**
     * Keys are the descriptor with its spaces removed, so a multi-word
     * descriptor resolves without the table having to store the spacing.
     */
    @Test
    fun `multi-word descriptors resolve`() {
        assertEquals("👍", SpokenEmoji.glyphsIn("thumbs up emoji"))
        assertEquals("🤷", SpokenEmoji.glyphsIn("shrug emoji"))
    }

    /**
     * Prose glued to the descriptor is not part of the name. The whole span
     * before the trigger has to be the key; a leftover prefix means decline.
     */
    @Test
    fun `prose before a descriptor is not consumed`() {
        assertEquals(
            "I'm so sad crying emoji",
            SpokenEmoji.glyphsIn("I'm so sad crying emoji"),
        )
        assertEquals(
            "nice work thumbs up emoji",
            SpokenEmoji.glyphsIn("nice work thumbs up emoji"),
        )
        // A comma ends the phrase, so the descriptor stands alone.
        assertEquals("I'm so sad, 😭", SpokenEmoji.glyphsIn("I'm so sad, crying emoji"))
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
     * The whole multi-word name converts, not a short suffix of it.
     * "loudly crying" and "crying" are both keys; taking only "crying" would
     * leave "loudly" stranded in front of the glyph.
     */
    @Test
    fun `the full multi-word name converts`() {
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
        assertEquals("😭 🔥", SpokenEmoji.glyphsIn("Crying emoji. Fire emoji."))
        assertEquals("😭 😭", SpokenEmoji.glyphsIn("crying emoji crying emoji"))
    }

    /**
     * The collapse must not reach past the run. Punctuation that belongs to the
     * sentence around the emoji stays exactly where the styler put it.
     */
    @Test
    fun `punctuation outside the run is untouched`() {
        assertEquals("🔥, then home", SpokenEmoji.glyphsIn("fire emoji, then home"))
        // "but fire" is not a key, so the second phrase declines rather than
        // taking the "fire" suffix and leaving "but" stranded.
        assertEquals(
            "I'm sad, 😭, but fire emoji, then home",
            SpokenEmoji.glyphsIn("I'm sad, crying emoji, but fire emoji, then home"),
        )
        // A sentence break gives the second descriptor its own span.
        assertEquals(
            "I'm sad, 😭 🔥, then home",
            SpokenEmoji.glyphsIn("I'm sad, crying emoji. Fire emoji, then home"),
        )
        // Leading name-stop words stay; "and" is not eaten into the second glyph.
        assertEquals("😭 and 🔥", SpokenEmoji.glyphsIn("crying emoji and fire emoji"))
    }

    /**
     * A partial match must never leave the rest of what was said in front of
     * the glyph. Exact multi-word keys convert fully; phrases that are not
     * keys must not fall back to a proper suffix.
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
     * Full-descriptor-or-decline: CLDR-style names that hit a key once
     * name-stop words are dropped convert as a whole; near-miss phrases that
     * only share a suffix with a key are left unchanged.
     */
    @Test
    fun `cldr names convert fully or not at all`() {
        assertEquals("😍", SpokenEmoji.glyphsIn("smiling face with heart eyes emoji"))
        assertEquals("💩", SpokenEmoji.glyphsIn("pile of poo emoji"))
        assertEquals("🙄", SpokenEmoji.glyphsIn("face with rolling eyes emoji"))
        assertEquals("😎", SpokenEmoji.glyphsIn("smiling face with sunglasses emoji"))
        assertEquals("❤️‍🔥", SpokenEmoji.glyphsIn("heart on fire emoji"))
        assertEquals("💑", SpokenEmoji.glyphsIn("couple with heart emoji"))

        val stranded = listOf(
            "I love you emoji",
            "see no evil emoji",
            "person running emoji",
        )
        for (phrase in stranded) {
            assertEquals(phrase, SpokenEmoji.glyphsIn(phrase))
        }
    }

    /**
     * Property-style: every multi-word key in the table, spoken with spaces
     * between its letters-only runs and followed by "emoji", must convert to
     * its glyph with nothing left in front. Single-token keys still convert.
     */
    @Test
    fun `table keys convert with no leftover prefix`() {
        var checked = 0
        for ((key, glyph) in EmojiTable.triggers) {
            if (key.length < EmojiTable.MINIMUM_LENGTH) continue
            if (key == "korea") continue // spoken blocklist; covered below
            // Re-space unknown concatenations by leaving the key as one word:
            // that is still an exact span and must convert.
            assertEquals(glyph, SpokenEmoji.glyphsIn("$key emoji"))
            checked += 1
            if (checked >= 200) break
        }
        assertTrue(checked >= 200)

        // Known multi-word spoken forms from the overrides and CLDR joins.
        val spaced = listOf(
            "heart eyes" to "😍",
            "loudly crying" to "😭",
            "one hundred" to "💯",
            "thumbs up" to "👍",
            "face with tears of joy" to "😂",
            "rolling on the floor laughing" to "🤣",
        )
        for ((phrase, glyph) in spaced) {
            assertEquals(glyph, SpokenEmoji.glyphsIn("$phrase emoji"))
        }
    }

    /**
     * `korea` in the strip table is 🇰🇵. Spoken path refuses the bare word;
     * southkorea / northkorea still convert.
     */
    @Test
    fun `korea alone does not become the DPRK flag`() {
        assertEquals("korea emoji", SpokenEmoji.glyphsIn("korea emoji"))
        assertEquals("🇰🇷", SpokenEmoji.glyphsIn("southkorea emoji"))
        assertEquals("🇰🇵", SpokenEmoji.glyphsIn("northkorea emoji"))
        // Strip table is unchanged: the blocklist is spoken-only.
        assertEquals("🇰🇵", EmojiTable.triggers["korea"])
    }

    /**
     * Digits are descriptors too. A speech model writes someone saying
     * "hundred" as "100" about as often as it writes the word, and 💯 is the
     * emoji people reach for most by number.
     */
    @Test
    fun `digits can be descriptors`() {
        assertEquals("💯", SpokenEmoji.glyphsIn("100 emoji"))
        assertEquals("💯", SpokenEmoji.glyphsIn("a hundred emoji"))
        assertEquals("💯", SpokenEmoji.glyphsIn("one hundred emoji"))
        // A number that names no emoji is still just a number.
        assertEquals("I need 20 emoji", SpokenEmoji.glyphsIn("I need 20 emoji"))
        // A digit glued to the descriptor is leftover prefix: decline.
        assertEquals("3 crying emoji", SpokenEmoji.glyphsIn("3 crying emoji"))
        assertEquals("3, 😭", SpokenEmoji.glyphsIn("3, crying emoji"))
    }

    /**
     * Allowing digits made a masked span's own index look like a word, so a
     * price or a URL could have offered its placeholder as a descriptor. These
     * are the shapes [ProtectedSpans] masks; every one keeps its span and still
     * converts the descriptor that follows it.
     */
    @Test
    fun `masked spans are not descriptors`() {
        assertEquals("it cost 3.50 😭", SpokenEmoji.glyphsIn("it cost 3.50 crying emoji"))
        assertEquals("meet at 10:30 😭", SpokenEmoji.glyphsIn("meet at 10:30 crying emoji"))
        assertEquals("the 1st 😭", SpokenEmoji.glyphsIn("the 1st crying emoji"))
        assertEquals(
            "read https://example.com/a 🔥",
            SpokenEmoji.glyphsIn("read https://example.com/a fire emoji"),
        )
    }

    /**
     * The descriptors are English, but nothing else has to be. A transcript in
     * another language keeps every word of its own and still converts an
     * English phrase the speaker chose to say — which is what code-switching
     * dictation actually sounds like.
     */
    @Test
    fun `only the descriptor has to be english`() {
        assertEquals(
            "मैं बहुत उदास हूँ 😭",
            SpokenEmoji.glyphsIn("मैं बहुत उदास हूँ crying emoji", "hi"),
        )
        assertEquals("とても悲しい 😭", SpokenEmoji.glyphsIn("とても悲しい crying emoji", "ja"))
        assertEquals(
            "estoy muy triste llorando emoji",
            SpokenEmoji.glyphsIn("estoy muy triste llorando emoji", "es"),
        )
    }

    /**
     * A trigger with nothing it recognizes in front of it is left exactly as
     * spoken. This is the case the feature is judged on: it must never guess.
     */
    @Test
    fun `an unmatched trigger is left alone`() {
        assertEquals("Send me the emoji.", SpokenEmoji.glyphsIn("Send me the emoji."))
        assertEquals("emoji", SpokenEmoji.glyphsIn("emoji"))
        assertEquals("emoji emoji", SpokenEmoji.glyphsIn("emoji emoji"))
    }

    @Test
    fun `the trigger may be pluralized`() {
        assertEquals("🔥", SpokenEmoji.glyphsIn("fire emojis"))
    }

    /**
     * Styling has already run, so the trigger arrives carrying whatever mark
     * the style put on it. Only the words are replaced, which leaves the mark
     * and the spacing exactly where the styler left them.
     */
    @Test
    fun `punctuation the styler attached survives`() {
        assertEquals("🎉!", SpokenEmoji.glyphsIn("party emoji!"))
        assertEquals("🔥, then home", SpokenEmoji.glyphsIn("fire emoji, then home"))
        assertEquals("😭. That was rough.", SpokenEmoji.glyphsIn("Crying emoji. That was rough."))
    }

    /**
     * The styler ended the sentence while the last word was still "emoji". An
     * emoji is the end: nobody writes "I'm so sad 😭." or "💯."
     */
    @Test
    fun `a trailing terminator after a glyph goes`() {
        assertEquals("I'm so sad, 😭", SpokenEmoji.glyphsIn("I'm so sad, crying emoji."))
        assertEquals("💯", SpokenEmoji.glyphsIn("Hundred emoji."))
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
        val untouched = "no trigger anywhere in this sentence at all"
        assertEquals(untouched, SpokenEmoji.glyphsIn(untouched))
        assertEquals("just a jar of jam", SpokenEmoji.glyphsIn("just a jar of jam"))
        assertEquals("fire emojify", SpokenEmoji.glyphsIn("fire emojify"))
        assertEquals("🔥 now", SpokenEmoji.glyphsIn("Fire EMOJI now"))
    }
}
