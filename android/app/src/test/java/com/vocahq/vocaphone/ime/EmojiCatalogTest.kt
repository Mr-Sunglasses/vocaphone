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
}
