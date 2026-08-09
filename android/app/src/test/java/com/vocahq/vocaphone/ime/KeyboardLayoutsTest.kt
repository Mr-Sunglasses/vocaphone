package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardLayoutsTest {

    @Test
    fun `every keyboard layer has four accessible rows`() {
        val editor = KeyboardEditorConfig.empty()

        KeyboardLayer.entries.forEach { layer ->
            val rows = KeyboardLayouts.rows(layer, editor)
            assertEquals(4, rows.size)
            assertTrue(rows.all { row -> row.keys.isNotEmpty() })
            assertTrue(rows.flatMap(KeyboardRow::keys).all { key -> key.weight > 0f })
        }
    }

    @Test
    fun `every layer keeps keyboard switch space and editor action available`() {
        val editor = KeyboardEditorConfig.empty()

        KeyboardLayer.entries.forEach { layer ->
            val bottomRow = KeyboardLayouts.rows(layer, editor).last().keys
            assertTrue(bottomRow.any { it.type == KeyboardKeyType.KEYBOARD_SWITCH })
            assertTrue(bottomRow.any { it.type == KeyboardKeyType.SPACE })
            assertTrue(bottomRow.any { it.type == KeyboardKeyType.RETURN })
        }
    }
}
