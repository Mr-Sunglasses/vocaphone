package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The romanizer is a spelling convention, so these are convention tests: one
 * spelling per word, chosen because it is the one people type. They are not
 * pinning a "correct" transliteration — several would be defensible — they are
 * pinning the one this repo committed to in `docs/hinglish-roman.md`, so that a
 * change to the rules cannot quietly change how every transcript reads.
 *
 * The grouping is by rule rather than by word, because each group is a rule that
 * has a visibly wrong naive answer.
 */
class DevanagariRomanizerTest {

    private fun assertRomanizes(vararg cases: Pair<String, String>) {
        cases.forEach { (devanagari, expected) ->
            assertEquals(devanagari, expected, DevanagariRomanizer.romanize(devanagari))
        }
    }

    @Test
    fun `implicit vowels are dropped at the end of a word`() {
        // Without this every word gains a syllable: "gharaa", "kalaa", "ekaa".
        assertRomanizes(
            "घर" to "ghar",
            "कल" to "kal",
            "एक" to "ek",
            "आज" to "aaj",
        )
    }

    @Test
    fun `implicit vowels are dropped mid-word before a written vowel`() {
        assertRomanizes(
            "करना" to "karna",
            "करनी" to "karni",
            "देखना" to "dekhna",
            "समझना" to "samajhna",
        )
    }

    @Test
    fun `implicit vowels survive where the next syllable has no written vowel`() {
        // समझ is the counterexample to the rule above: ज carries no written
        // vowel either, so the schwa on म is pronounced and "samjh" is wrong.
        assertRomanizes(
            "समझ" to "samajh",
            "भारत" to "bhaarat",
        )
    }

    @Test
    fun `the first syllable never loses its implicit vowel`() {
        // Without the guard पता collapses to "pta", which is unreadable.
        assertRomanizes(
            "पता" to "pata",
            "बताना" to "bataana",
        )
    }

    @Test
    fun `long vowels shorten only at the end of a word`() {
        assertRomanizes(
            "ठीक" to "theek",
            "कभी" to "kabhi",
            "काम" to "kaam",
            "बात" to "baat",
            "साथ" to "saath",
            "मेरी" to "meri",
            "दूसरा" to "doosra",
        )
    }

    @Test
    fun `a trailing nasal does not make the vowel before it non-final`() {
        // "naheen" and "hoon" for these would both be wrong for the same reason.
        assertRomanizes(
            "नहीं" to "nahin",
            "हूँ" to "hun",
            "मैं" to "main",
            "हैं" to "hain",
        )
    }

    @Test
    fun `anusvara is m before a lip consonant and n everywhere else`() {
        assertRomanizes(
            "संभव" to "sambhav",
            "अंदर" to "andar",
        )
    }

    @Test
    fun `conjuncts keep both consonants and no vowel between them`() {
        assertRomanizes(
            "क्या" to "kya",
            "नमस्ते" to "namaste",
            "अच्छा" to "achchha",
            "कुछ" to "kuchh",
        )
    }

    @Test
    fun `nukta letters take their own sounds`() {
        assertRomanizes(
            "ज़रूर" to "zaroor",
            "फ़ोन" to "fon",
            "बड़ा" to "bara",
        )
    }

    @Test
    fun `devanagari digits and danda become their latin equivalents`() {
        assertRomanizes(
            "१२३" to "123",
            "ठीक।" to "theek.",
        )
    }

    @Test
    fun `latin text passes through untouched`() {
        val english = "Deploy the API to staging at 4:30 PM, then ping me."
        assertEquals(english, DevanagariRomanizer.romanize(english))
        assertFalse(DevanagariRomanizer.containsDevanagari(english))
    }

    @Test
    fun `a code-switched sentence keeps its english half verbatim`() {
        assertEquals(
            "aaj mujhe office men ek important meeting attend karni hai",
            DevanagariRomanizer.romanize(
                "आज मुझे office में एक important meeting attend करनी है",
            ),
        )
    }

    @Test
    fun `nothing devanagari survives romanization`() {
        val mixed = "कल मेरी client के साथ deployment meeting है। ठीक है ना?"
        assertTrue(DevanagariRomanizer.containsDevanagari(mixed))
        assertFalse(DevanagariRomanizer.containsDevanagari(DevanagariRomanizer.romanize(mixed)))
    }

    @Test
    fun `romanizing twice changes nothing the second time`() {
        val once = DevanagariRomanizer.romanize("आज मुझे office में meeting है")
        assertEquals(once, DevanagariRomanizer.romanize(once))
    }
}
