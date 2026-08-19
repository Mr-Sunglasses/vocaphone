package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EmojiSuggestionsTest {

    @Test
    fun expectedWordsOfferTheirEmoji() {
        assertEquals("😂", EmojiSuggestions.glyph("lol"))
        assertEquals("🍕", EmojiSuggestions.glyph("pizza"))
        assertEquals("🎂", EmojiSuggestions.glyph("birthday"))
        assertEquals("🙏", EmojiSuggestions.glyph("thanks"))
        assertEquals("🔥", EmojiSuggestions.glyph("fire"))
        assertEquals("😊", EmojiSuggestions.glyph("happy"))
        assertEquals("😢", EmojiSuggestions.glyph("sad"))
        assertEquals("💀", EmojiSuggestions.glyph("skull"))
    }

    @Test
    fun matchingIgnoresCase() {
        assertEquals("😂", EmojiSuggestions.glyph("LOL"))
        assertEquals("🍕", EmojiSuggestions.glyph("Pizza"))
    }

    @Test
    fun onlyWholeWordsMatch() {
        assertNull(EmojiSuggestions.glyph("lolly"))
        assertNull(EmojiSuggestions.glyph("carefully"))
        assertEquals("🚗", EmojiSuggestions.glyph("car"))
        assertNull(EmojiSuggestions.glyph("l"))
        assertNull(EmojiSuggestions.glyph(""))
    }

    @Test
    fun ordinaryProseGetsNothing() {
        for (word in listOf(
            "the", "and", "is", "was", "of", "to", "it", "that", "this", "with",
            "have", "from", "they", "there", "about", "would", "should",
            "good", "yes", "no", "time", "work", "day", "code", "check", "key",
        )) {
            assertNull(word, EmojiSuggestions.glyph(word))
        }
    }

    @Test
    fun feelingWordsOfferRelatedEmoji() {
        assertEquals(listOf("😢", "😭", "😞"), EmojiSuggestions.glyphs("sad"))
        assertEquals(listOf("😊", "😄", "😁"), EmojiSuggestions.glyphs("happy"))
        assertTrue(EmojiSuggestions.glyphs("skull").contains("💀"))
        assertTrue(EmojiSuggestions.glyphs("skull").size > 1)
    }

    @Test
    fun aliasesShareTheSameGlyphAndRelatedChips() {
        assertEquals("😂", EmojiSuggestions.glyph("laugh"))
        assertEquals("😂", EmojiSuggestions.glyph("lol"))
        assertEquals("😢", EmojiSuggestions.glyph("unhappy"))
        assertEquals(EmojiSuggestions.glyphs("sad"), EmojiSuggestions.glyphs("upset"))
        assertEquals("🙏", EmojiSuggestions.glyph("thx"))
        assertEquals("🎂", EmojiSuggestions.glyph("bday"))
        assertEquals("🤷", EmojiSuggestions.glyph("idk"))
    }

    @Test
    fun everyEntryIsOneEmojiForOneLowercaseWord() {
        for ((word, glyph) in EmojiSuggestions.TRIGGERS) {
            assertEquals(word, word.lowercase())
            assertTrue(word.length >= EmojiSuggestions.MINIMUM_LENGTH)
            assertTrue(word, word.all { it.isLetter() })
            assertTrue(glyph.isNotEmpty())
            assertTrue(word, glyph.any { !it.isLetter() })
        }
    }

    @Test
    fun theTableIsCuratedRatherThanExhaustive() {
        assertTrue(EmojiSuggestions.TRIGGERS.size > 100)
        assertTrue(EmojiSuggestions.TRIGGERS.size < 400)
    }

    /**
     * Every glyph the strip can offer is one the shipped catalog also carries.
     *
     * The trigger table is curated by hand and stays that way -- CLDR's
     * keywords are for a deliberate search in the emoji panel, and matched
     * against ordinary prose they answer "the" with an emoji. What the table
     * has no way to catch on its own is a glyph that nothing can draw. The
     * catalog is generated from a pinned Unicode release, so agreeing with it
     * is what rules out pasting in a draft codepoint that renders as a blank
     * box on every phone in the field.
     */
    @Test
    fun `every offered emoji exists in the shipped catalog`() {
        val catalog = generateSequence(java.io.File("").absoluteFile) { it.parentFile }
            .map { java.io.File(it, "assets/keyboard/emoji/catalog.tsv") }
            .firstOrNull(java.io.File::isFile)
        org.junit.Assume.assumeTrue(
            "assets/keyboard is only present in the repository",
            catalog != null,
        )
        val known = catalog!!.readLines()
            .mapNotNull { line -> line.substringBefore('\t').takeIf { it.isNotEmpty() } }
            .toSet()

        val offered = EmojiSuggestions.TRIGGERS.keys
            .flatMap { EmojiSuggestions.glyphs(it) }
            .toSortedSet()
        assertTrue("the catalog looks empty", known.size > 1_000)
        val missing = offered.filterNot { it in known }
        assertEquals("offered but not in the catalog", emptyList<String>(), missing)
    }
}
