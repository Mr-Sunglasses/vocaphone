package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NeverSuggestTest {
    private val list = NeverSuggest.parse(
        listOf(
            "# comment",
            "*\tslur\tslurword",
            "en\tswear\tdarn",
            "en\tslur\tcarpet thing",
            "en\tswear\tholy cow",
            "de\tslur\tnurdeutsch",
            "",
        ),
    )

    @Test
    fun `slurs are always held back and swears only with the setting off`() {
        assertTrue(list.blocks("slurword", allowSwears = true))
        assertTrue(list.blocks("Slurword", allowSwears = false))
        assertTrue(list.blocks("darn", allowSwears = false))
        assertFalse(list.blocks("darn", allowSwears = true))
        assertFalse(list.blocks("hello", allowSwears = false))
    }

    @Test
    fun `only every-layout and English rows are read`() {
        assertFalse(list.blocks("nurdeutsch", allowSwears = false))
    }

    @Test
    fun `a two-word expression blocks only its second word after its first`() {
        assertFalse(list.blocks("thing", allowSwears = false))
        assertTrue(list.blocks("thing", previous = "carpet", allowSwears = true))
        assertFalse(list.blocks("thing", previous = "rug", allowSwears = false))
        assertTrue(list.blocks("cow", previous = "Holy", allowSwears = false))
        assertFalse(list.blocks("cow", previous = "holy", allowSwears = true))
    }

    @Test
    fun `the shipped list parses and holds back what it lists`() {
        val file = generateSequence(java.io.File("").absoluteFile) { it.parentFile }
            .map { java.io.File(it, "assets/keyboard/never-suggest.tsv") }
            .first { it.exists() }
        val shipped = NeverSuggest.parse(file.readLines())
        val rows = file.readLines().filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split('\t') }
            .filter { it[0] == "*" || it[0] == "en" }
        assertTrue(rows.isNotEmpty())
        for (row in rows) {
            val words = row[2].split(' ')
            val slur = row[1] == "slur"
            val blocked = if (words.size == 1) {
                shipped.blocks(words[0], allowSwears = true)
            } else {
                shipped.blocks(words[1], previous = words[0], allowSwears = true)
            }
            assertEquals(row.joinToString(" "), slur, blocked)
        }
    }

    @Test
    fun `the strip never offers a held-back word but keeps the user's own`() {
        val dictionary = SuggestionDictionary(
            words = listOf("darning", "darn", "dart", "slurword", "slurwords"),
            bigrams = mapOf("holy" to listOf("cow", "moly")),
            neverSuggest = list,
        )
        assertEquals(listOf("darning", "dart"), dictionary.strip("dar", "", "", correctionsEnabled = true).words)
        // The setting lets swear words back in.
        val swears = dictionary.strip("dar", "", "", correctionsEnabled = true, options = StripOptions(allowSwears = true))
        assertEquals(listOf("darning", "darn", "dart"), swears.words)
        // A slur stays out with the setting on; the personal dictionary is the user's.
        val slur = dictionary.strip("slurw", "", "", true, options = StripOptions(allowSwears = true)).words
        assertTrue("slurword" !in slur)
        assertTrue("slurwords" in slur)
        assertTrue("slurword" in dictionary.strip("slurw", "", "", true, personalRaw = "slurword").words)
        assertEquals(listOf("moly"), dictionary.strip("", "holy ", "", true).words)
        assertEquals(listOf("cow", "moly"), dictionary.strip("", "holy ", "", true, options = StripOptions(allowSwears = true)).words)
    }

    @Test
    fun `a held-back word typed in full is not corrected away`() {
        val dictionary = SuggestionDictionary(
            words = listOf("dare", "dark"),
            bigrams = emptyMap(),
            neverSuggest = list,
        )
        assertTrue(dictionary.strip("darn", "", "", correctionsEnabled = true).words.isEmpty())
        assertTrue(dictionary.strip("", "darn", "", correctionsEnabled = true).words.isEmpty())
        assertEquals(listOf("dark", "dare"), dictionary.strip("darj", "", "", correctionsEnabled = true).words)
    }

    @Test
    fun `swipe results skip held-back words`() {
        val dictionary = SuggestionDictionary(
            words = listOf("darn", "dawn"),
            bigrams = emptyMap(),
            neverSuggest = list,
        )
        val gate = { word: String -> dictionary.allows(word, null, allowSwears = false, personal = emptySet()) }
        assertTrue("darn" !in dictionary.swipe("dsarn", allowed = gate))
        assertTrue("darn" in dictionary.swipe("dsarn", allowed = { dictionary.allows(it, null, false, setOf("darn")) }))
    }
}
