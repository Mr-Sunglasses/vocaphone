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
        assertEquals("🦩", EmojiSuggestions.glyph("flamingo"))
        assertEquals("🎷", EmojiSuggestions.glyph("saxophone"))
        assertEquals("👍", EmojiSuggestions.glyph("thumbsup"))
        assertEquals("🦖", EmojiSuggestions.glyph("trex"))
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
    fun uniqueAlmostFinishedPrefixOffersTheGlyph() {
        assertEquals("🍕", EmojiSuggestions.glyph("pizz"))
        assertEquals("☕", EmojiSuggestions.glyph("coffe"))
        assertEquals(listOf("😢", "😭", "😞"), EmojiSuggestions.glyphs("unhap"))
    }

    @Test
    fun shortOrAmbiguousPrefixesOfferNothing() {
        assertNull(EmojiSuggestions.glyph("hap"))
        assertNull(EmojiSuggestions.glyph("co"))
        // "read" is a real word, three letters short of "reading". Offering 📚
        // here is the same failure as matching catalog keywords.
        assertNull(EmojiSuggestions.glyph("read"))
    }

    @Test
    fun uniqueInsertOrDeleteOffersTheGlyph() {
        assertEquals("🍕", EmojiSuggestions.glyph("piza"))
        assertEquals("☕", EmojiSuggestions.glyph("cofee"))
        assertEquals("😊", EmojiSuggestions.glyph("happpy"))
    }

    @Test
    fun substitutionDoesNotOfferANearbyTrigger() {
        // "read" is one substitution from "dead". That must not become 💀.
        assertNull(EmojiSuggestions.glyph("read"))
        assertEquals("💀", EmojiSuggestions.glyph("dead"))
    }

    @Test
    fun aLeadingExtraLetterDoesNotTurnAParticleIntoATrigger() {
        // "they" is "t" + "hey". Offering 👋 there is the strip crying wolf.
        assertNull(EmojiSuggestions.glyph("they"))
        assertEquals("👋", EmojiSuggestions.glyph("hey"))
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
            // Letters, or digits for the handful of curated keys that are a
            // number — "100" is 💯, and SpokenEmoji needs it because a model
            // writes a spoken "hundred" that way. The generator still refuses
            // anything else, and its auto path is alphabetic regardless.
            assertTrue(word, word.all { it.isLetterOrDigit() })
            assertTrue(glyph.isNotEmpty())
            assertTrue(word, glyph.any { !it.isLetter() })
        }
    }

    @Test
    fun distinctiveNamesAreOffered() {
        assertEquals("🌵", EmojiSuggestions.glyph("cactus"))
        assertEquals("🐧", EmojiSuggestions.glyph("penguin"))
        assertEquals("🦄", EmojiSuggestions.glyph("unicorn"))
        assertEquals("🧮", EmojiSuggestions.glyph("abacus"))
        assertEquals("🐉", EmojiSuggestions.glyph("dragon"))
        assertEquals("🌭", EmojiSuggestions.glyph("hotdog"))
    }

    @Test
    fun theTableCoversMostNamedEmoji() {
        assertTrue(EmojiSuggestions.TRIGGERS.size > 2_000)
        assertTrue(EmojiSuggestions.TRIGGERS.values.toSet().size > 1_500)
    }

    /**
     * Every glyph the strip can offer is one the shipped catalog also carries.
     *
     * The table is generated from the same Unicode release as the catalog, plus
     * a short override list. CLDR's keywords stay out of it -- matched against
     * ordinary prose they answer "the" with an emoji. Agreeing with the
     * catalog is what rules out a draft codepoint that renders as a blank box
     * on every phone in the field.
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
