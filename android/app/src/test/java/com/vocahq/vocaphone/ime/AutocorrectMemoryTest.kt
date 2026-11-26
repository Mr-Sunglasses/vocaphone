package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutocorrectMemoryTest {
    private val never = NeverSuggest.parse(listOf("*\tslur\tslurword", "en\tswear\tdarn"))

    private fun fix(
        typed: String,
        memory: AutocorrectMemory,
        known: Set<String> = emptySet(),
        personal: List<String> = emptyList(),
    ) = LearnedFixes.fixFor(
        typed = typed,
        memory = memory,
        isWord = { it.lowercase() in known || personal.any { p -> p.equals(it, ignoreCase = true) } },
        blocked = { never.blocks(it, allowSwears = false) },
        personalSpelling = { f -> personal.firstOrNull { it.equals(f, ignoreCase = true) } },
    )

    @Test
    fun `a pair undone twice is rejected, once is not`() {
        val once = AutocorrectMemory.EMPTY.withRejection("teh", "the")
        assertFalse(once.isRejected("teh", "the"))
        val twice = once.withRejection("TEH", "The")
        assertTrue(twice.isRejected("teh", "the"))
        assertFalse(twice.isRejected("teh", "ten"))
    }

    @Test
    fun `a typo fixed the same way twice is learned`() {
        val once = AutocorrectMemory.EMPTY.withPick("teh", "the")
        assertNull(once.learnedFix("teh"))
        val twice = once.withPick("Teh", "The")
        assertEquals("the", twice.learnedFix("teh"))
    }

    @Test
    fun `a typo fixed two different ways is never learned`() {
        val memory = AutocorrectMemory.EMPTY
            .withPick("hte", "the").withPick("hte", "the").withPick("hte", "hate")
        assertNull(memory.learnedFix("hte"))
    }

    @Test
    fun `a learned fix undone twice is not made again`() {
        val memory = AutocorrectMemory.EMPTY.withPick("teh", "the").withPick("teh", "the")
        assertEquals("the", fix("teh", memory))
        val undone = memory.withRejection("teh", "the").withRejection("teh", "the")
        assertNull(fix("teh", undone))
    }

    @Test
    fun `undone twice, a learned fix is unlearned, not just suppressed`() {
        val learned = AutocorrectMemory.EMPTY.withPick("teh", "the").withPick("teh", "the").withPick("teh", "tea")
        val once = learned.withRejection("teh", "the")
        assertEquals(2, once.picks["teh"]?.get("the"))
        val twice = once.withRejection("teh", "the")
        assertNull(twice.picks["teh"]?.get("the"))
        assertEquals(1, twice.picks["teh"]?.get("tea"))
        val only = AutocorrectMemory.EMPTY.withPick("hte", "the").withRejection("hte", "the").withRejection("hte", "the")
        assertNull(only.picks["hte"])
        assertTrue(only.isRejected("hte", "the"))
    }

    @Test
    fun `space keeps the typed capitalisation`() {
        val memory = AutocorrectMemory.EMPTY.withPick("teh", "the").withPick("teh", "the")
        assertEquals("the", fix("teh", memory))
        assertEquals("The", fix("Teh", memory))
        assertEquals("THE", fix("TEH", memory))
    }

    @Test
    fun `never when the typed word is a word, or the fix is held back`() {
        val memory = AutocorrectMemory.EMPTY
            .withPick("ten", "the").withPick("ten", "the")
            .withPick("darb", "darn").withPick("darb", "darn")
        assertNull(fix("ten", memory, known = setOf("ten")))
        assertNull(fix("ten", memory, personal = listOf("Ten")))
        assertNull(fix("darb", memory))
    }

    @Test
    fun `a learned fix in the personal dictionary keeps its spelling`() {
        val memory = AutocorrectMemory.EMPTY.withPick("vocaphne", "VocaPhone").withPick("Vocaphne", "Vocaphone")
        assertEquals("VocaPhone", fix("vocaphne", memory, personal = listOf("VocaPhone")))
    }

    @Test
    fun `only corrections count, not completions`() {
        assertTrue(LearnedFixes.isCorrection("teh", "the"))
        assertFalse(LearnedFixes.isCorrection("hel", "hello"))
        assertFalse(LearnedFixes.isCorrection("the", "The"))
        assertFalse(LearnedFixes.isCorrection("t", "the"))
    }

    @Test
    fun `the store round-trips and stays bounded`() {
        val memory = AutocorrectMemory.EMPTY
            .withPick("teh", "the").withPick("teh", "the")
            .withRejection("recieve", "receive")
        assertEquals(memory, AutocorrectMemory.decode(memory.encode()))
        assertEquals(AutocorrectMemory.EMPTY, AutocorrectMemory.decode("garbage\nr\tonly\ttwo"))
        var big = AutocorrectMemory.EMPTY
        repeat(AutocorrectMemory.CAPACITY + 20) { big = big.withPick("typo$it", "fix$it") }
        assertEquals(AutocorrectMemory.CAPACITY, big.picks.size)
        assertNull(big.picks["typo0"])
    }

    @Test
    fun `the undo puts the typed word back in place of the fix and its space`() {
        assertEquals(
            KeyboardCommand.ReplaceBeforeCursor(4, "teh"),
            AutocorrectUndo(typed = "teh", fixed = "the", boundary = " ").deleteCommand(),
        )
    }

    @Test
    fun `the strip leads with a learned fix and never with a rejected one`() {
        val dictionary = SuggestionDictionary(listOf("the", "then", "ten", "tea"), emptyMap())
        val learned = AutocorrectMemory.EMPTY.withPick("teh", "tea").withPick("teh", "tea")
        val strip = dictionary.strip("teh", "", "", true, options = StripOptions(memory = learned, learnedFixes = true))
        assertEquals("tea", strip.words.first())
        // "ten" is a neighbouring key away, so it leads on its own.
        val plain = dictionary.strip("teh", "", "", true)
        assertEquals("ten", plain.words.first())
        val rejected = AutocorrectMemory.EMPTY.withRejection("teh", "ten").withRejection("teh", "ten")
        val demoted = dictionary.strip("teh", "", "", true, options = StripOptions(memory = rejected))
        assertTrue(demoted.words.first() != "ten")
        assertTrue("ten" in demoted.words)
    }
}
