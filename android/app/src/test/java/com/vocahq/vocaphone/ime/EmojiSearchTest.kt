package com.vocahq.vocaphone.ime

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EmojiSearchTest {
    private val catalog: List<EmojiEntry> by lazy {
        val file = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "assets/keyboard/emoji/catalog.tsv") }
            .first { it.exists() }
        EmojiCatalog.parse(file.readLines().asSequence())
    }
    private val tones by lazy { EmojiTones.build(catalog) }

    @Test
    fun theShippedCatalogHasTonesForHands() {
        val thumbs = tones.variantsOf("👍")!!
        assertEquals(listOf("👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"), thumbs)
        // The base keeps its variation selector; its tones do not have one.
        assertEquals(5, tones.variantsOf("☝️")!!.size)
        assertTrue(tones.isToned("👍🏽"))
        assertFalse(tones.isToned("👍"))
        assertNull(tones.variantsOf("😀"))
    }

    @Test
    fun theDefaultToneIsApplied() {
        assertEquals("👍🏿", tones.applied("👍", 5))
        assertEquals("👍", tones.applied("👍", 0))
        assertEquals("😀", tones.applied("😀", 3))
    }

    @Test
    fun searchFindsByNameAndKeywordAndLeavesTonesOut() {
        val pizza = EmojiSearch.search(catalog, "pizza", tones)
        assertEquals("🍕", pizza.first())
        val thumbs = EmojiSearch.search(catalog, "thumbs", tones)
        assertTrue("👍" in thumbs)
        assertFalse(thumbs.any { tones.isToned(it) })
    }

    @Test
    fun everyWordMustStartAKeyword() {
        val results = EmojiSearch.search(catalog, "red hea", tones)
        assertTrue("❤️" in results)
        assertTrue(EmojiSearch.search(catalog, "zzqx", tones).isEmpty())
        assertTrue(EmojiSearch.search(catalog, "   ", tones).isEmpty())
    }

    @Test
    fun aPrefixInsideAWordDoesNotMatch() {
        // "izza" is inside "pizza" but starts no word.
        assertFalse("🍕" in EmojiSearch.search(catalog, "izza", tones))
    }

    @Test
    fun toneKeysIgnoreModifiersAndVariationSelectors() {
        assertEquals(EmojiTones.key("☝️"), EmojiTones.key("☝🏽"))
        assertEquals(3, EmojiTones.toneOf(0x1F3FD))
        assertEquals(0, EmojiTones.toneOf('a'.code))
    }
}
