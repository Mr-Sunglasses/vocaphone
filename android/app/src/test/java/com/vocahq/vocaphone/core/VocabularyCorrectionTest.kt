package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The same cases as `VocabularyCorrectionTests.swift`. */
class VocabularyCorrectionTest {
    private val dictionary = setOf("strip", "vocal", "phone", "must", "whisper", "kit", "is", "here")

    private fun corrected(text: String, vararg terms: String) =
        VocabularyCorrection.apply(text, terms.toList()) { it in dictionary }

    @Test
    fun `spacing and case are fixed`() {
        assertEquals("I use WhisperKit daily.", corrected("I use whisper kit daily.", "WhisperKit"))
        assertEquals("Open VocaPhone now", corrected("Open vocaphone now", "VocaPhone"))
        assertEquals("Open VocaPhone now", corrected("Open Voca Phone now", "VocaPhone"))
    }

    @Test
    fun `one letter out is fixed`() {
        assertEquals("Kanishk is here.", corrected("Kanish is here.", "Kanishk"))
        assertEquals("Try VocaPhone.", corrected("Try vocal phone.", "VocaPhone"))
    }

    @Test
    fun `punctuation stays put`() {
        assertEquals("Kanishk's laptop, then Kanishk.", corrected("Kanish's laptop, then Kanish.", "Kanishk"))
        assertEquals("(WhisperKit)", corrected("(whisper kit)", "WhisperKit"))
    }

    @Test
    fun `dictionary words are left alone`() {
        assertEquals("Strip the wire.", corrected("Strip the wire.", "Stripe"))
        assertEquals("You must go.", corrected("You must go.", "Rust"))
    }

    @Test
    fun `short terms are never fuzzy`() {
        assertEquals("The cat sat.", corrected("The cat sat.", "Cats"))
        assertEquals("Use Rust here", corrected("Use rust here", "Rust"))
    }

    @Test
    fun `a term does not cross punctuation`() {
        assertEquals("vocal, phone", corrected("vocal, phone", "VocaPhone"))
    }

    @Test
    fun `a correct term is left as it is`() {
        assertEquals("VocaPhone s app", corrected("VocaPhone s app", "VocaPhone"))
    }

    @Test
    fun `different first letters are different words`() {
        assertEquals("Fanishk called", corrected("Fanishk called", "Kanishk"))
    }

    @Test
    fun `multi word terms match across their words`() {
        assertEquals("ask Claude Code about it", corrected("ask claude code about it", "Claude Code"))
    }

    @Test
    fun `nothing to do`() {
        assertEquals("", corrected("", "VocaPhone"))
        assertEquals("Hello there.", corrected("Hello there."))
    }

    @Test
    fun `the funnel applies it except for raw`() {
        val casual = DictatedTranscript.finished(
            "send it to kanish",
            style = WritingStyle.CASUAL,
            repairSpeech = false,
            vocabulary = listOf("Kanishk"),
        )
        assertTrue(casual, casual.contains("Kanishk"))
        val raw = DictatedTranscript.finished(
            "send it to kanish",
            style = WritingStyle.RAW,
            repairSpeech = false,
            vocabulary = listOf("Kanishk"),
        )
        assertTrue(raw, !raw.contains("Kanishk"))
    }
}
