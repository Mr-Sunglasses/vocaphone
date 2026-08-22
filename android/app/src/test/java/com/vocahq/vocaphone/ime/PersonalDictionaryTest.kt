package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PersonalDictionaryTest {

    @Test
    fun parsesCommasAndNewlinesAndKeepsTheFirstSpelling() {
        val terms = PersonalDictionary.terms("Kanishk, vocahq\nKanishk\nVocaPhone")
        assertEquals(listOf("Kanishk", "vocahq", "VocaPhone"), terms)
    }

    @Test
    fun completionsPreferSavedSpellingForLowercasePrefixes() {
        val raw = "Kanishk\nVocaPhone"
        assertEquals(listOf("Kanishk"), PersonalDictionary.completions(raw, "kan"))
        assertEquals(listOf("KANISHK"), PersonalDictionary.completions(raw, "KAN"))
        assertTrue(PersonalDictionary.completions(raw, "zzz").isEmpty())
        assertTrue(PersonalDictionary.completions(raw, "kanishk").isEmpty())
    }

    @Test
    fun addPutsTheNewWordFirstAndDropsDuplicates() {
        val added = PersonalDictionary.add("vocahq\nKanishk", "VocaPhone")
        assertEquals("VocaPhone, vocahq, Kanishk", added)
        assertEquals(
            "kanishk, vocahq",
            PersonalDictionary.add("vocahq\nKanishk", "kanishk"),
        )
    }

    @Test
    fun normalizeWritesACommaSeparatedList() {
        assertEquals(
            "Kanishk, vocahq, VocaPhone",
            PersonalDictionary.normalize("Kanishk, vocahq\nVocaPhone"),
        )
        assertEquals("", PersonalDictionary.normalize("  \n , "))
    }

    @Test
    fun rejectsShortAndNonWordTokens() {
        assertFalse(PersonalDictionary.isSavable("ab"))
        assertFalse(PersonalDictionary.isSavable("hel2"))
        assertFalse(PersonalDictionary.isSavable("@kanishk"))
        assertTrue(PersonalDictionary.isSavable("O'Brien"))
        assertEquals("", PersonalDictionary.add("", "ok"))
    }

    @Test
    fun containsIsCaseInsensitive() {
        assertTrue(PersonalDictionary.contains("Kanishk", "kanishk"))
        assertFalse(PersonalDictionary.contains("Kanishk", "kan"))
    }
}
