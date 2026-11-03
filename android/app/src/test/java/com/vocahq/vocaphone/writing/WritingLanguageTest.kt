package com.vocahq.vocaphone.writing

import com.vocahq.vocaphone.core.TranscriptRepair
import com.vocahq.vocaphone.spell.SpellCheckSpans
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WritingLanguageTest {
    private val check = WritingCheck(WritingFixtures.rules)

    /** The keyboard's word list, as the spell checker service reads it from its assets. */
    private val englishWords: Set<String> by lazy {
        val file = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "assets/keyboard/en.txt") }
            .first(File::isFile)
        file.readLines().map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toHashSet()
    }

    private fun isEnglish(text: String) = TranscriptRepair.isEnglish(text, "auto") { it in englishWords }

    private fun report(text: String) =
        check.check(text, null, WritingCheck.Options(setOf(WritingCategory.CORRECTNESS), typed = true))

    /** What the system spell checker underlines in [text], as "original → suggestion". */
    private fun underlines(text: String): List<String> =
        SpellCheckSpans.checked(text, ::isEnglish) { report(text) }
            .filter { it.kind != SpellCheckSpans.Kind.FINE }
            .map { "${text.substring(it.offset, it.offset + it.length)} → ${it.suggestions.single()}" }

    @Test
    fun `a French sentence gets no English suggestions`() {
        val french = "C'est le livre dont elle parle."
        // The rules alone would offer "don't" for the French "dont".
        assertTrue(SpellCheckSpans.of(french, report(french)).any { it.kind != SpellCheckSpans.Kind.FINE })
        assertEquals(emptyList<String>(), underlines(french))
    }

    @Test
    fun `a French sentence still reports every word fine, so old underlines clear`() {
        val french = "C'est le livre dont elle parle."
        val spans = SpellCheckSpans.checked(french, ::isEnglish) { error("the rules should not run") }
        assertEquals(setOf(SpellCheckSpans.Kind.FINE), spans.map { it.kind }.toSet())
        assertEquals(listOf("C'est", "le", "livre", "dont", "elle", "parle"), spans.map { french.substring(it.offset, it.offset + it.length) })
    }

    @Test
    fun `an English sentence of six words or more is still checked`() {
        assertEquals(listOf("helps → help"), underlines("I was wondering if you could helps."))
    }

    @Test
    fun `a borrowed accented word does not hide the rest of an English sentence`() {
        val sentence = "I definately want to visit the café."
        // The transcript test alone calls any accented letter foreign.
        assertFalse(isEnglish(sentence))
        assertEquals(listOf("definately → definitely"), underlines(sentence))
    }

    @Test
    fun `a sentence with many accented words is not English`() {
        assertFalse(WritingLanguage.isEnglish("El niño está en la casa grande") { true })
        assertFalse(WritingLanguage.applies("Ça a été une très belle journée, merci") { true })
    }

    @Test
    fun `a few accents do not make another language English`() {
        // One accented word in eight is allowed; the other seven are French.
        val french = "Je pense que nous irons au café demain"
        assertFalse(WritingLanguage.applies(french, ::isEnglish))
    }

    @Test
    fun `French that borrows nothing but an accent is not English`() {
        // Every word but "C'est" and "café" is in the English list, and the
        // rules would offer "don't" for "dont".
        val french = "C'est le café dont tu as le menu."
        assertFalse(WritingLanguage.applies(french, ::isEnglish))
        assertEquals(emptyList<String>(), underlines(french))
    }

    @Test
    fun `the rest is asked without the borrowed words`() {
        var asked = ""
        WritingLanguage.isEnglish("we met at the café on monday") { asked = it; true }
        assertEquals("we met at the on monday", asked)
        WritingLanguage.isEnglish("plain english text") { asked = it; true }
        assertEquals("plain english text", asked)
    }

    @Test
    fun `a single misspelled word is still checked`() {
        assertEquals(listOf("definately → definitely"), underlines("definately"))
    }

    @Test
    fun `under six words the language is not asked`() {
        assertTrue(WritingLanguage.applies("le livre dont elle parle") { error("not asked") })
    }

    @Test
    fun `six words or more are checked only when English`() {
        assertFalse(WritingLanguage.applies("one two three four five six") { false })
        assertTrue(WritingLanguage.applies("one two three four five six") { true })
    }

    @Test
    fun `pieces without a letter are not words`() {
        assertTrue(WritingLanguage.applies("one two — 42 three four five") { false })
    }

    @Test
    fun `text without letters is not checked`() {
        assertFalse(WritingLanguage.applies("") { true })
        assertFalse(WritingLanguage.applies("42 — 7:30 !!") { true })
    }

    private fun typed(text: String) = WritingLanguage.applies(text) {
        WritingLanguage.typedEnglish(it, { w -> w in englishWords }, WritingFixtures.spelling)
    }

    /** The more typos, the surer the transcript test was that text was foreign; the keyboards never checked it. */
    @Test
    fun `typed English with many typos is still English`() {
        for (text in listOf(
            "Teh airport wil be busy",
            "Teh aiport wil be busy tomorow",
            "Recieved teh pacakge, thanks alot Sam",
            "teh meeting wil be tommorow at noon",
            "Pls snd me teh invoce for Acme asap",
            "teh kids plays outsdie evry evening aftr school",
            "kal meeting hai, please send the deck to me",
            // "per" is English too: the foreign-word veto must not count it.
            "The rate is per hour, not per day, and not per week or per month",
            "Are you going to Los Angeles or Las Vegas this year",
        )) assertTrue(text, typed(text))
    }

    @Test
    fun `other languages typed in Latin letters are still not English`() {
        for (text in listOf(
            "Je ne sais pas ce que tu veux dire",
            "Voici la personne dont elle parle souvent.",
            "kal milte hai bro tu aa jana time pe",
            "no se que hacer con mi vida ahora",
            "Ich habe keine Zeit heute abend fur dich",
        )) assertFalse(text, typed(text))
    }

    @Test
    fun `a slip of a marker word counts as the marker`() {
        assertEquals("the", WritingLanguage.markerSlip("teh"))
        assertEquals("because", WritingLanguage.markerSlip("becuase"))
        assertEquals("their", WritingLanguage.markerSlip("thier"))
        assertEquals("really", WritingLanguage.markerSlip("realy"))
        assertEquals(null, WritingLanguage.markerSlip("the"))
        assertEquals(null, WritingLanguage.markerSlip("hai"))
    }
}
