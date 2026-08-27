package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EmojiCatalogTest {

    private val catalog = EmojiCatalog.parse(
        sequenceOf(
            "😀\tsmileys\tgrinning face smile happy",
            "😂\tsmileys\tface tears joy laugh",
            "👍\tpeople\tthumbs up yes",
            "🚀\ttravel\trocket space launch",
        ),
    )

    @Test
    fun `category filter keeps matching glyphs`() {
        assertEquals(
            listOf("😀", "😂"),
            EmojiCatalog.inCategory(catalog, EmojiCategory.SMILEYS).map { it.glyph },
        )
        assertEquals(
            listOf("🚀"),
            EmojiCatalog.inCategory(catalog, EmojiCategory.TRAVEL).map { it.glyph },
        )
        assertTrue(EmojiCatalog.inCategory(catalog, EmojiCategory.FOOD).isEmpty())
    }

    @Test
    fun `ascii category is a built-in emoticon list`() {
        assertTrue(EmojiCatalog.asciiEmoticons.contains(":)"))
        assertTrue(EmojiCatalog.asciiEmoticons.contains("¯\\_(ツ)_/¯"))
        assertTrue(EmojiCategory.browsable(asciiEnabled = true).contains(EmojiCategory.ASCII))
        assertTrue(EmojiCategory.ASCII !in EmojiCategory.browsable(asciiEnabled = false))
    }

    @Test
    fun `shipped catalog includes concatenated names people type`() {
        val catalog = generateSequence(java.io.File("").absoluteFile) { it.parentFile }
            .map { java.io.File(it, "assets/keyboard/emoji/catalog.tsv") }
            .firstOrNull(java.io.File::isFile)
        org.junit.Assume.assumeTrue(
            "assets/keyboard is only present in the repository",
            catalog != null,
        )
        val byGlyph = catalog!!.readLines().associate { line ->
            val tab = line.indexOf('\t')
            val second = line.indexOf('\t', tab + 1)
            line.substring(0, tab) to line.substring(second + 1)
        }
        assertTrue(byGlyph.getValue("👍").contains("thumbsup"))
        assertTrue(byGlyph.getValue("🌭").contains("hotdog"))
        assertTrue(byGlyph.getValue("🦖").contains("trex"))
    }
}
