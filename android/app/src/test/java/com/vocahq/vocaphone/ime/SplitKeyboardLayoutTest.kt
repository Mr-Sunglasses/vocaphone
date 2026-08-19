package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.settings.SplitKeyboard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SplitKeyboardLayoutTest {

    @Test
    fun `stored values survive a round trip and unknown reads as auto`() {
        SplitKeyboard.entries.forEach { mode ->
            assertEquals(mode, SplitKeyboard.fromStored(mode.storedValue))
        }
        assertEquals(listOf("auto", "always", "never"), SplitKeyboard.entries.map { it.storedValue })
        assertEquals(SplitKeyboard.AUTO, SplitKeyboard.fromStored(null))
        assertEquals(SplitKeyboard.AUTO, SplitKeyboard.fromStored("thumbs"))
        assertEquals(SplitKeyboard.AUTO, SplitKeyboard.DEFAULT)
    }

    @Test
    fun `auto leaves a phone portrait keyboard alone`() {
        assertFalse(SplitKeyboardLayout.shouldSplit(SplitKeyboard.AUTO, 360))
        assertFalse(SplitKeyboardLayout.shouldSplit(SplitKeyboard.AUTO, 411))
        assertFalse(SplitKeyboardLayout.shouldSplit(SplitKeyboard.AUTO, 599))
    }

    @Test
    fun `auto splits at 600 dp and stays split on a fold inner`() {
        assertTrue(SplitKeyboardLayout.shouldSplit(SplitKeyboard.AUTO, 600))
        assertTrue(SplitKeyboardLayout.shouldSplit(SplitKeyboard.AUTO, 690))
        assertTrue(SplitKeyboardLayout.shouldSplit(SplitKeyboard.AUTO, 840))
    }

    @Test
    fun `auto splits phone landscape and fold-cover landscape`() {
        // Auto is "IME too wide for thumbs", not tablet-only. A phone or
        // fold cover turned sideways is ~640-900 dp, so it splits. Do not
        // raise this to sw600dp / 800 dp to spare landscape.
        assertTrue(SplitKeyboardLayout.shouldSplit(SplitKeyboard.AUTO, 640))
        assertTrue(SplitKeyboardLayout.shouldSplit(SplitKeyboard.AUTO, 800))
        assertTrue(SplitKeyboardLayout.shouldSplit(SplitKeyboard.AUTO, 914))
    }

    @Test
    fun `always and never ignore width`() {
        assertTrue(SplitKeyboardLayout.shouldSplit(SplitKeyboard.ALWAYS, 360))
        assertFalse(SplitKeyboardLayout.shouldSplit(SplitKeyboard.NEVER, 1200))
    }

    @Test
    fun `spacer grows from 15 to 35 percent of keyboard width`() {
        assertEquals(0.15f, SplitKeyboardLayout.spacerFraction(360), 0.0001f)
        assertEquals(0.15f, SplitKeyboardLayout.spacerFraction(600), 0.0001f)
        assertEquals(0.25f, SplitKeyboardLayout.spacerFraction(660), 0.0001f)
        assertEquals(0.35f, SplitKeyboardLayout.spacerFraction(720), 0.0001f)
        assertEquals(0.35f, SplitKeyboardLayout.spacerFraction(1200), 0.0001f)
    }

    @Test
    fun `spacer weight is the fraction of the finished row`() {
        val keys = 10f
        val gap = SplitKeyboardLayout.spacerWeight(keys, 0.20f)
        assertEquals(0.20f, gap / (keys + gap), 0.0001f)
    }

    @Test
    fun `letter rows keep order and insert a gap near the middle`() {
        val qwerty = KeyboardLayouts.rows(KeyboardLayer.LETTERS, KeyboardEditorConfig.empty())[0]
        val split = SplitKeyboardLayout.splitRow(qwerty, 0.20f)
        assertEquals(
            listOf("q", "w", "e", "r", "t", "y", "u", "i", "o", "p"),
            split.items.filterIsInstance<SplitItem.Key>().map { it.key.output },
        )
        assertEquals(5, split.items.indexOfFirst { it is SplitItem.Gap })
        assertEquals(1, split.items.count { it is SplitItem.Gap })
    }

    @Test
    fun `home row splits after five letters so the gap sits near center`() {
        val home = KeyboardLayouts.rows(KeyboardLayer.LETTERS, KeyboardEditorConfig.empty())[1]
        val split = SplitKeyboardLayout.splitRow(home, 0.20f)
        val letters = split.items.filterIsInstance<SplitItem.Key>().map { it.key.output }
        assertEquals(listOf("a", "s", "d", "f", "g", "h", "j", "k", "l"), letters)
        assertEquals(
            listOf("a", "s", "d", "f", "g"),
            split.items.takeWhile { it is SplitItem.Key }.map { (it as SplitItem.Key).key.output },
        )
    }

    @Test
    fun `spacebar becomes two space keys with a gap between them`() {
        val bottom = KeyboardLayouts.rows(KeyboardLayer.LETTERS, KeyboardEditorConfig.empty()).last()
        assertFalse(
            SplitKeyboardLayout.isSplitSpace(bottom.keys.first { it.type == KeyboardKeyType.SPACE }),
        )
        val split = SplitKeyboardLayout.splitRow(bottom, 0.20f)
        val keys = split.items.filterIsInstance<SplitItem.Key>().map { it.key }
        val spaces = keys.filter { it.type == KeyboardKeyType.SPACE }
        assertEquals(2, spaces.size)
        assertTrue(spaces.all { SplitKeyboardLayout.isSplitSpace(it) })
        assertGapBetweenSpaces(split.items)
        assertEquals(bottom.keys.first().id, keys.first().id)
        assertEquals(bottom.keys.last().id, keys.last().id)
    }

    @Test
    fun `emoji bottom row splits the spacebar and leaves other keys in order`() {
        val bottom = KeyboardLayouts.rows(KeyboardLayer.EMOJI, KeyboardEditorConfig.empty()).single()
        val split = SplitKeyboardLayout.splitRow(bottom, 0.20f)
        val keys = split.items.filterIsInstance<SplitItem.Key>().map { it.key }
        assertEquals(
            listOf(
                KeyboardKeyType.LAYER_SWITCH,
                KeyboardKeyType.SPACE,
                KeyboardKeyType.SPACE,
                KeyboardKeyType.DELETE,
                KeyboardKeyType.RETURN,
            ),
            keys.map { it.type },
        )
        assertGapBetweenSpaces(split.items)
        assertEquals("emoji-letters", keys.first().id)
        assertEquals("return", keys.last().id)
    }

    private fun assertGapBetweenSpaces(items: List<SplitItem>) {
        val gap = items.indexOfFirst { it is SplitItem.Gap }
        assertEquals(1, items.count { it is SplitItem.Gap })
        assertTrue(gap > 0 && gap < items.lastIndex)
        val left = items[gap - 1] as SplitItem.Key
        val right = items[gap + 1] as SplitItem.Key
        assertEquals(KeyboardKeyType.SPACE, left.key.type)
        assertEquals(KeyboardKeyType.SPACE, right.key.type)
        assertTrue(SplitKeyboardLayout.isSplitSpace(left.key))
        assertTrue(SplitKeyboardLayout.isSplitSpace(right.key))
    }

    @Test
    fun `number layer rows still split without dropping keys`() {
        val rows = KeyboardLayouts.rows(KeyboardLayer.NUMBERS, KeyboardEditorConfig.empty())
        rows.forEach { row ->
            val split = SplitKeyboardLayout.splitRow(row, 0.15f)
            val original = row.keys.map { it.id to it.type }
            val rebuilt = split.items.filterIsInstance<SplitItem.Key>().map { item ->
                val key = item.key
                if (key.type == KeyboardKeyType.SPACE) {
                    "space" to KeyboardKeyType.SPACE
                } else {
                    key.id to key.type
                }
            }.distinct()
            val expected = original.map { (id, type) ->
                if (type == KeyboardKeyType.SPACE) "space" to type else id to type
            }
            assertEquals(expected, rebuilt)
        }
    }
}
