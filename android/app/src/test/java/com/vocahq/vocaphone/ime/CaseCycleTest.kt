package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
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
    fun `several words cycle camel, sentence title, upper, then lower`() {
        assertEquals("hello World", CaseCycle.next("hello world"))
        assertEquals("Hello world", CaseCycle.next("hello World"))
        assertEquals("HELLO WORLD", CaseCycle.next("Hello world"))
        assertEquals("hello world", CaseCycle.next("HELLO WORLD"))
    }

    @Test
    fun `title case capitalizes only the first word`() {
        assertEquals("Hello world there", CaseCycle.next("hello World There"))
    }

    @Test
    fun `apostrophes stay inside the word`() {
        assertEquals("don't Stop", CaseCycle.next("don't stop"))
        assertEquals("Don't stop", CaseCycle.next("don't Stop"))
        assertEquals("DON'T STOP", CaseCycle.next("Don't stop"))
    }

    @Test
    fun `text with no letters is left alone`() {
        assertEquals("123", CaseCycle.next("123"))
        assertEquals("", CaseCycle.next(""))
    }
}
