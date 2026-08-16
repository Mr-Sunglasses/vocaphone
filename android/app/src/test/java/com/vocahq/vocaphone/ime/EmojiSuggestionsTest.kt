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
}
