package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyAccentsTest {

    @Test
    fun numberKeysOfferTheMatchingSymbol() {
        val expected = mapOf(
            "1" to "!",
            "2" to "@",
            "3" to "#",
            "4" to "$",
            "5" to "%",
            "6" to "^",
            "7" to "&",
            "8" to "*",
            "9" to "(",
            "0" to ")",
        )
        expected.forEach { (digit, symbol) ->
            val key = KeyboardKey(id = digit, label = digit, output = digit)
            val variants = KeyAccents.forKey(key, ShiftState.OFF)
            assertTrue("$digit should long-press to $symbol", symbol in variants)
        }
    }

    @Test
    fun letterKeysStillOfferAccents() {
        val key = KeyboardKey(id = "e", label = "e", output = "e")
        assertEquals("é", KeyAccents.forKey(key, ShiftState.OFF)[1])
    }

    @Test
    fun numberKeysShowTheLongPressHint() {
        assertEquals("!", KeyAccents.hint(KeyboardKey(id = "1", label = "1", output = "1")))
        assertEquals(")", KeyAccents.hint(KeyboardKey(id = "0", label = "0", output = "0")))
        assertEquals(null, KeyAccents.hint(KeyboardKey(id = "e", label = "e", output = "e")))
    }
}
