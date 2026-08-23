package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CaseCycleTest {

    @Test
    fun `a single word cycles title, upper, then lower`() {
        assertEquals("Hello", CaseCycle.next("hello"))
        assertEquals("HELLO", CaseCycle.next("Hello"))
        assertEquals("hello", CaseCycle.next("HELLO"))
    }

    @Test
    fun `two shift taps take a lowercase word to all caps`() {
        assertEquals("HELLO", CaseCycle.next(CaseCycle.next("hello")))
    }

    @Test
    fun `several words cycle title, upper, then lower`() {
        assertEquals("Hello world", CaseCycle.next("hello world"))
        assertEquals("HELLO WORLD", CaseCycle.next("Hello world"))
        assertEquals("hello world", CaseCycle.next("HELLO WORLD"))
    }

    @Test
    fun `mixed original spelling comes back after lower`() {
        val original = "iPhone"
        val title = CaseCycle.next(original, original)
        val upper = CaseCycle.next(title, original)
        val lower = CaseCycle.next(upper, original)
        val restored = CaseCycle.next(lower, original)
        assertEquals("Iphone", title)
        assertEquals("IPHONE", upper)
        assertEquals("iphone", lower)
        assertEquals("iPhone", restored)
    }

    @Test
    fun `title case capitalizes only the first word`() {
        assertEquals("Hello world there", CaseCycle.next("hello World There"))
    }

    @Test
    fun `apostrophes stay inside the word`() {
        assertEquals("Don't stop", CaseCycle.next("don't stop"))
        assertEquals("DON'T STOP", CaseCycle.next("Don't stop"))
        assertEquals("don't stop", CaseCycle.next("DON'T STOP"))
    }

    @Test
    fun `text with no letters is left alone`() {
        assertEquals("123", CaseCycle.next("123"))
        assertEquals("", CaseCycle.next(""))
    }

    @Test
    fun `a composing span must restore the selection after finish`() {
        val plan = planCaseCycle(
            selected = "hello",
            original = "hello",
            start = 4,
            composingActive = true,
        )!!
        assertEquals("Hello", plan.next)
        assertEquals(4, plan.start)
        assertEquals(9, plan.end)
        assertTrue(plan.restoreSelectionAfterFinish)
    }

    @Test
    fun `no composing span does not finish composing first`() {
        val plan = planCaseCycle(
            selected = "hello",
            original = "hello",
            start = 0,
            composingActive = false,
        )!!
        assertFalse(plan.restoreSelectionAfterFinish)
    }
}
