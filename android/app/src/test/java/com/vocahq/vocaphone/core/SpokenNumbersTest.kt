package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The opt-in conversion is intentionally more defined by its refusals than by
 * the happy path: a wrong digit conversion makes every transcript harder to
 * trust and undo.
 */
class SpokenNumbersTest {
    private fun converted(text: String): String = SpokenNumbers.digitsIn(text)

    @Test
    fun `times quantities and compound numbers become digits`() {
        assertEquals("6 pm at office", converted("six pm at office"))
        assertEquals("call me at 8 am", converted("call me at eight am"))
        assertEquals("11 o'clock", converted("eleven o'clock"))
        assertEquals("I need 5 copies", converted("I need five copies"))
        assertEquals("0 results", converted("zero results"))
        assertEquals("19 days later", converted("nineteen days later"))
        assertEquals("23 people", converted("twenty three people"))
        assertEquals("23 people", converted("twenty-three people"))
        assertEquals("250", converted("two hundred and fifty"))
        assertEquals("2500", converted("twenty five hundred"))
        assertEquals("2003500", converted("two million three thousand five hundred"))
    }

    @Test
    fun `decimals are read digit by digit`() {
        assertEquals("3.5 hours", converted("three point five hours"))
        assertEquals("3.14", converted("three point one four"))
        assertEquals("0.5", converted("zero point five"))
    }

    @Test
    fun `case and surrounding punctuation survive`() {
        assertEquals("20 people came.", converted("Twenty people came."))
        assertEquals("at 6, then 7.", converted("at six, then seven."))
        assertEquals("(23)", converted("(twenty three)"))
        assertEquals("6!", converted("six!"))
    }

    @Test
    fun `a lone one is kept as a word unless a quantity unit follows`() {
        assertEquals("no one came", converted("no one came"))
        assertEquals("one of them is broken", converted("one of them is broken"))
        assertEquals("one day I'll get to it", converted("one day I'll get to it"))
        assertEquals("that's the one", converted("that's the one"))
        assertEquals("one another", converted("one another"))
        assertEquals("a one-off thing", converted("a one-off thing"))
        assertEquals("see you at 1 pm", converted("see you at one pm"))
        assertEquals("1 hour later", converted("one hour later"))
        assertEquals("1 percent of them", converted("one percent of them"))
        assertEquals("1 kg of rice", converted("one kg of rice"))
        assertEquals("one, pm", converted("one, pm"))
        assertEquals("one\npm", converted("one\npm"))
    }

    @Test
    fun `one within an unambiguous number converts`() {
        assertEquals("21 people", converted("twenty one people"))
        assertEquals("1000", converted("one thousand"))
        assertEquals("101", converted("one hundred and one"))
    }

    @Test
    fun `adjacent numbers and spoken times are not guessed`() {
        assertEquals("six seven", converted("six seven"))
        assertEquals("one two three four", converted("one two three four"))
        assertEquals("nineteen eighty four", converted("nineteen eighty four"))
        assertEquals("twenty twenty five", converted("twenty twenty five"))
        assertEquals("meet me at seven thirty", converted("meet me at seven thirty"))
    }

    @Test
    fun `ordinals and their preceding number stay as spoken`() {
        assertEquals("first of May", converted("first of May"))
        assertEquals("second thoughts", converted("second thoughts"))
        assertEquals("the twenty first", converted("the twenty first"))
        assertEquals("the twenty-first", converted("the twenty-first"))
        assertEquals("her thirtieth birthday", converted("her thirtieth birthday"))
        assertEquals("a 5 second delay", converted("a five second delay"))
        assertEquals("1 second please", converted("one second please"))
    }

    @Test
    fun `connectors and impossible number combinations are kept safely`() {
        assertEquals("hundreds of people", converted("hundreds of people"))
        assertEquals("that is the point", converted("that is the point"))
        assertEquals("you and I", converted("you and I"))
        assertEquals("between 5 and 10", converted("between five and ten"))
        assertEquals("2 and 3", converted("two and three"))
        assertEquals("200 and the rest", converted("two hundred and the rest"))
        assertEquals("5 point Nemo", converted("five point Nemo"))
        assertEquals("zero hundred", converted("zero hundred"))
        assertEquals("twenty hundred", converted("twenty hundred"))
        assertEquals("three thousand two million", converted("three thousand two million"))
    }

    @Test
    fun `the supported maximum converts and other text passes through`() {
        val largest = "nine hundred ninety nine billion nine hundred ninety nine million " +
            "nine hundred ninety nine thousand nine hundred ninety nine"
        assertEquals("999999999999", converted(largest))
        assertEquals(999_999_999_999L, SpokenNumbers.MAXIMUM)
        assertEquals("one trillion", converted("one trillion"))
        assertEquals("call 9876543210 now", converted("call 9876543210 now"))
        assertEquals("version 2.1 is out", converted("version 2.1 is out"))
        assertEquals("मुझे तीन कॉपी चाहिए", converted("मुझे तीन कॉपी चाहिए"))
        assertEquals("necesito cinco copias", converted("necesito cinco copias"))
        assertEquals("someone told me", converted("someone told me"))
        assertEquals("20\n3", converted("twenty\nthree"))
    }
}
