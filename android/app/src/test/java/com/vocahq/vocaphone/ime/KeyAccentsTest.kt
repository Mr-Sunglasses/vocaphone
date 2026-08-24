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

    @Test
    fun letterKeysShowGboardSymbolsWhenEnabled() {
        val e = KeyboardKey(id = "e", label = "e", output = "e")
        val a = KeyboardKey(id = "a", label = "a", output = "a")
        val q = KeyboardKey(id = "q", label = "q", output = "q")
        assertEquals("3", KeyAccents.hint(e, longPressSymbols = true))
        assertEquals("@", KeyAccents.hint(a, longPressSymbols = true))
        assertEquals("1", KeyAccents.hint(q, longPressSymbols = true, numberRow = false))
        assertEquals("[", KeyAccents.hint(q, longPressSymbols = true, numberRow = true))
        assertEquals("@", KeyAccents.hint(a, longPressSymbols = true, numberRow = true))
        assertEquals(null, KeyAccents.hint(e, longPressSymbols = false))
    }

    @Test
    fun longPressSymbolsSitInFrontOfAccents() {
        val e = KeyboardKey(id = "e", label = "e", output = "e")
        val off = KeyAccents.forKey(e, ShiftState.OFF)
        assertEquals("è", off.first())
        assertTrue("3" !in off)

        val on = KeyAccents.forKey(e, ShiftState.OFF, longPressSymbols = true)
        assertEquals("3", on.first())
        assertTrue("è" in on)

        val shifted = KeyAccents.forKey(e, ShiftState.ONCE, longPressSymbols = true)
        assertEquals("3", shifted.first())
        assertTrue("È" in shifted)
    }

    @Test
    fun qLongPressesToOneWithoutANumberRowAndBracketWithOne() {
        val q = KeyboardKey(id = "q", label = "q", output = "q")
        assertTrue(KeyAccents.forKey(q, ShiftState.OFF).isEmpty())
        assertEquals(listOf("1"), KeyAccents.forKey(q, ShiftState.OFF, longPressSymbols = true))
        assertEquals(
            listOf("["),
            KeyAccents.forKey(q, ShiftState.OFF, longPressSymbols = true, numberRow = true),
        )
    }

    @Test
    fun qwertyMirrorsTheSymbolsPageWhenTheNumberRowIsShowing() {
        val expected = mapOf(
            "q" to "[", "w" to "]", "e" to "{", "r" to "}", "t" to "#",
            "y" to "%", "u" to "^", "i" to "*", "o" to "+", "p" to "=",
        )
        expected.forEach { (letter, symbol) ->
            val key = KeyboardKey(id = letter, label = letter, output = letter)
            assertEquals(
                symbol,
                KeyAccents.hint(key, longPressSymbols = true, numberRow = true),
            )
            assertTrue(
                "$letter should long-press to $symbol",
                symbol in KeyAccents.forKey(key, ShiftState.OFF, longPressSymbols = true, numberRow = true),
            )
        }
    }
}
