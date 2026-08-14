package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardLayoutsTest {

    @Test
    fun `letter keyboard grows by one row when the number row is on`() {
        val editor = KeyboardEditorConfig.empty()
        assertEquals(4, KeyboardLayouts.rows(KeyboardLayer.LETTERS, editor, numberRow = false).size)
        assertEquals(5, KeyboardLayouts.rows(KeyboardLayer.LETTERS, editor, numberRow = true).size)
        assertEquals(
            listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "0"),
            KeyboardLayouts.rows(KeyboardLayer.LETTERS, editor, numberRow = true).first().keys.map { it.output },
        )
    }

    @Test
    fun `bottom row keeps space and editor action and has no globe key`() {
        val editor = KeyboardEditorConfig.empty()
        KeyboardLayer.entries.forEach { layer ->
            val bottomRow = KeyboardLayouts.rows(layer, editor).last().keys
            assertTrue(bottomRow.any { it.type == KeyboardKeyType.SPACE })
            assertTrue(bottomRow.any { it.type == KeyboardKeyType.RETURN })
            assertFalse(bottomRow.any { it.label == "Switch keyboard" })
        }
    }

    @Test
    fun `number and symbol layers keep five rows so they fill the letter height`() {
        val editor = KeyboardEditorConfig.empty()
        assertEquals(5, KeyboardLayouts.rows(KeyboardLayer.NUMBERS, editor).size)
        assertEquals(5, KeyboardLayouts.rows(KeyboardLayer.SYMBOLS, editor).size)
        assertEquals(5, KeyboardLayouts.rows(KeyboardLayer.SYMBOLS, editor, numberRow = true).size)
    }

    @Test
    fun `letter bottom row balances weight around the spacebar`() {
        val bottom = KeyboardLayouts.rows(KeyboardLayer.LETTERS, KeyboardEditorConfig.empty()).last()
        val spaceIndex = bottom.keys.indexOfFirst { it.type == KeyboardKeyType.SPACE }
        val left = bottom.keys.take(spaceIndex).sumOf { it.weight.toDouble() }
        val right = bottom.keys.drop(spaceIndex + 1).sumOf { it.weight.toDouble() }
        assertEquals(left, right, 0.01)
    }
}
