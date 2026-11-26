package com.vocahq.vocaphone.ime

import android.text.InputType
import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PadLayoutsTest {
    private fun editor(type: Int) = KeyboardEditorConfig.from(EditorInfo().apply { inputType = type }, sessionId = 1)

    @Test
    fun phoneFieldsGetTheDialPad() {
        val config = editor(InputType.TYPE_CLASS_PHONE)
        assertEquals(KeyboardLayer.PHONE, config.initialLayer)
        val rows = KeyboardLayouts.rows(KeyboardLayer.PHONE, config)
        assertEquals(4, rows.size)
        assertEquals(listOf("1", "2", "3", "-"), rows[0].keys.map { it.output })
        assertEquals("ABC", rows[0].keys[1].caption)
        assertEquals("WXYZ", rows[2].keys[2].caption)
        assertTrue(rows[1].keys.any { it.type == KeyboardKeyType.SPACE })
        assertTrue(rows.last().keys.any { it.output == "+" })
        assertTrue(rows.last().keys.any { it.type == KeyboardKeyType.RETURN })
    }

    @Test
    fun numberFieldsGetTheNumberPad() {
        val config = editor(InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL)
        val rows = KeyboardLayouts.rows(KeyboardLayer.NUMPAD, config)
        assertEquals(4, rows.size)
        assertEquals(listOf("7", "8", "9"), rows[2].keys.take(3).map { it.output })
        assertTrue(rows[2].keys.last().type == KeyboardKeyType.DELETE)
        val outputs = rows.flatMap { row -> row.keys.map { it.output } }
        assertTrue("." in outputs && "-" in outputs && "," in outputs)
    }

    @Test
    fun dateFieldsGetSeparators() {
        val config = editor(InputType.TYPE_CLASS_DATETIME)
        assertEquals(PadKind.DATETIME, config.padKind)
        val outputs = KeyboardLayouts.rows(KeyboardLayer.NUMPAD, config).flatMap { row -> row.keys.map { it.output } }
        assertTrue("/" in outputs && ":" in outputs)
    }

    @Test
    fun theSymbolsPageLeadsBackToThePad() {
        val config = editor(InputType.TYPE_CLASS_PHONE)
        val symbolsKey = KeyboardLayouts.rows(KeyboardLayer.PHONE, config).last().keys.first()
        assertEquals(KeyboardLayer.NUMBERS, symbolsKey.targetLayer)
        val back = KeyboardLayouts.rows(KeyboardLayer.NUMBERS, config).last().keys.first()
        assertEquals(KeyboardLayer.PHONE, back.targetLayer)
        // An ordinary field's symbols page still goes back to the letters.
        val letters = KeyboardLayouts.rows(KeyboardLayer.NUMBERS, KeyboardEditorConfig.empty()).last().keys.first()
        assertEquals(KeyboardLayer.LETTERS, letters.targetLayer)
    }

    @Test
    fun padDigitsOfferNoLetterSymbolsOnHold() {
        val config = editor(InputType.TYPE_CLASS_NUMBER)
        val two = KeyboardLayouts.rows(KeyboardLayer.NUMPAD, config)[0].keys[1]
        assertEquals(emptyList<String>(), KeyAccents.forKey(two, ShiftState.OFF))
        val point = KeyboardLayouts.rows(KeyboardLayer.NUMPAD, config).last().keys.first { it.output == "." }
        assertEquals(listOf(","), KeyAccents.forKey(point, ShiftState.OFF))
        assertEquals(",", KeyAccents.hint(point))
    }
}
