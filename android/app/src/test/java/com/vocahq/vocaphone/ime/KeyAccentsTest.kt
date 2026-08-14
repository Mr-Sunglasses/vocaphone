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
}
