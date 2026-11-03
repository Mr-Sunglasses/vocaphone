package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Sound-alike correction: Double Metaphone, the wider budget for a spelling
 * that sounds like a term, and several words joined into one term when the
 * engine was unsure of them. The same cases as `SoundAlikeCorrectionTests.swift`.
 */
class SoundAlikeCorrectionTest {
    /** Ordinary words, as the shipped word list would answer for them. */
    private val dictionary = setOf(
        "the", "to", "in", "it", "is", "a", "and", "ask", "about", "call", "tomorrow", "deploy", "now",
        "train", "cloud", "roll", "buy", "cooper", "pans", "pie", "torch", "for", "dessert", "then",
        "down", "open", "today", "please", "kaiser", "netties",
    )

    private fun corrected(text: String, vararg terms: String, unsure: Set<String>? = null) =
        VocabularyCorrection.apply(
            text, terms.toList(), isDictionaryWord = { it in dictionary }, lowConfidenceWords = unsure,
        )

    private fun key(word: String) = DoubleMetaphone.encode(word)

    // Double Metaphone

    /** Reference values from the Apache Commons Codec implementation. */
    @Test
    fun `known keys`() {
        assertEquals(DoubleMetaphone.Key("SM0", "XMT"), key("Smith"))
        assertEquals(DoubleMetaphone.Key("XMT", "SMT"), key("Schmidt"))
        assertEquals("TMS", key("Thomas")?.primary)
        assertEquals("NT", key("knight")?.primary)
        assertEquals("SF", key("Xavier")?.primary)
        assertEquals("SSR", key("Caesar")?.primary)
        assertEquals("FLP", key("Philip")?.primary)
        assertEquals("HS", key("Jose")?.primary)
        assertEquals("LF", key("laugh")?.primary)
    }

    @Test
    fun `sound-alike spellings share a key`() {
        val pairs = listOf(
            "kubernetes" to "coopernetties", "kaiser" to "kayzer", "pachauri" to "pachori",
            "stephen" to "steven", "catherine" to "kathryn", "philip" to "fillip",
            "postgresql" to "postgersql",
        )
        for ((a, b) in pairs) {
            val left = key(a)!!
            val right = key(b)!!
            assertTrue("$a $left vs $b $right", left.matches(right))
        }
    }

    @Test
    fun `different words do not share a key`() {
        for ((a, b) in listOf("kubernetes" to "cucumbers", "namrata" to "tamrata", "kaiser" to "kolmar")) {
            val left = key(a)!!
            val right = key(b)!!
            assertFalse("$a $left vs $b $right", left.matches(right))
        }
    }

    @Test
    fun `only English letters are keyed`() {
        assertNull(key("müller"))
        assertNull(key("gpt4"))
        assertNull(key(""))
        assertEquals("A", key("aeiou")?.primary)
        assertEquals(4, DoubleMetaphone.encode("Schwarzenegger", maxLength = 4)?.primary?.length)
    }

    @Test
    fun soundex() {
        assertEquals("r163", VocabularyCorrection.soundex("robert"))
        assertEquals("r163", VocabularyCorrection.soundex("rupert"))
        assertEquals("a261", VocabularyCorrection.soundex("ashcraft"))
        assertEquals("t522", VocabularyCorrection.soundex("tymczak"))
        assertEquals("p236", VocabularyCorrection.soundex("pfister"))
        assertNull(VocabularyCorrection.soundex("gpt4"))
        assertNull(VocabularyCorrection.soundex("müller"))
    }

    @Test
    fun `first sound`() {
        assertEquals('k', VocabularyCorrection.firstSound("cooper"))
        assertEquals('k', VocabularyCorrection.firstSound("quick"))
        assertEquals('s', VocabularyCorrection.firstSound("zebra"))
        assertEquals('f', VocabularyCorrection.firstSound("philip"))
        assertEquals('p', VocabularyCorrection.firstSound("pie"))
    }

    // A wider budget for what sounds alike

    @Test
    fun `sounding alike gets one more edit`() {
        assertEquals("call Kaiser tomorrow", corrected("call Kayzer tomorrow", "Kaiser"))
        // Two edits that do not sound alike stay put.
        assertEquals("call Kolmar tomorrow", corrected("call Kolmar tomorrow", "Kaiser"))
    }

    @Test
    fun `long terms that sound alike get two more edits`() {
        assertEquals("ask Pachauri about it", corrected("ask Pachori about it", "Pachauri"))
        assertEquals("replace it with PostgreSQL now", corrected("replace it with Postgersql now", "PostgreSQL"))
    }

    @Test
    fun `sounding alike still spares ordinary words`() {
        assertEquals("the kaiser roll", corrected("the kaiser roll", "Kayzer"))
        assertEquals("ask the cloud", corrected("ask the cloud", "Claude", unsure = setOf("cloud")))
    }

    @Test
    fun `a different first letter needs the same sound`() {
        // c and k are one sound, and the words sound alike.
        assertEquals("ask Kasper now", corrected("ask Casper now", "Kasper"))
        // Same first sound, but not alike: a different first letter stays.
        // (The comma keeps "Kolmarz now", whose letters do sound like it, from
        // being joined into the term.)
        assertEquals("ask Kolmarz, now", corrected("ask Kolmarz, now", "Calmerson"))
        assertEquals("ask Tamrata about it", corrected("ask Tamrata about it", "Namrata"))
    }

    // Several words heard for one

    @Test
    fun `real words that sound like a term join only when the engine was unsure`() {
        assertEquals(
            "deploy to Kubernetes now",
            corrected("deploy to cooper netties now", "Kubernetes", unsure = setOf("netties")),
        )
        assertEquals(
            "train it in PyTorch",
            corrected("train it in pie torch", "PyTorch", unsure = setOf("pie", "torch")),
        )
        // Sure of the words, or no confidence reported: left as heard.
        assertEquals(
            "deploy to cooper netties now",
            corrected("deploy to cooper netties now", "Kubernetes", unsure = emptySet()),
        )
        assertEquals("deploy to cooper netties now", corrected("deploy to cooper netties now", "Kubernetes"))
    }

    /** From an engine that reports nothing, a word off the list is the only evidence there is. */
    @Test
    fun `an unknown word in the run is evidence enough`() {
        assertEquals("deploy to Kubernetes now", corrected("deploy to cooper netteez now", "Kubernetes"))
    }

    /**
     * From an engine that reports confidence, only its doubt counts: a word off
     * the list, such as a name, is not evidence it misheard.
     */
    @Test
    fun `an engine that reports confidence must have doubted a word`() {
        val text = "he said Ruth, a little dubiously"
        fun joined(unsure: Set<String>?) = VocabularyCorrection.apply(
            text,
            listOf("Siddharth"),
            isDictionaryWord = { it in setOf("he", "said", "a", "little", "dubiously") },
            lowConfidenceWords = unsure,
        )
        assertEquals(text, joined(emptySet()))
        assertEquals(text, joined(setOf("little")))
        assertEquals("he Siddharth, a little dubiously", joined(null))
        assertEquals(
            "deploy to cooper netteez now",
            corrected("deploy to cooper netteez now", "Kubernetes", unsure = emptySet()),
        )
        assertEquals(
            "deploy to Kubernetes now",
            corrected("deploy to cooper netteez now", "Kubernetes", unsure = setOf("netteez")),
        )
    }

    @Test
    fun `sound-alike join needs the whole key`() {
        assertEquals(
            "buy cooper pans now",
            corrected("buy cooper pans now", "Kubernetes", unsure = setOf("cooper", "pans")),
        )
    }

    /** A term that is itself an ordinary word could be any run of words that sounds like it. */
    @Test
    fun `a term that is an ordinary word is never joined`() {
        val text = "deploy to cooper netteez now"
        assertEquals(
            text,
            VocabularyCorrection.apply(
                text, listOf("Kubernetes"), isDictionaryWord = { it in dictionary || it == "kubernetes" },
            ),
        )
    }

    /** One unsure "pie" must not let a confidently heard "pie torch" elsewhere become PyTorch. */
    @Test
    fun `a word heard once sure is never unsure`() {
        var confidence = RecognitionConfidence.UNREPORTED
        for ((word, probability) in listOf(
            " pie" to 0.31, " for" to 0.98, " dessert" to 0.97, " then" to 0.99, " pie" to 0.96, " torch" to 0.95,
        )) {
            confidence = confidence.add(word, probability)
        }
        assertEquals(emptySet<String>(), confidence.lowConfidenceWords)
        assertEquals(
            "pie for dessert then pie torch",
            corrected("pie for dessert then pie torch", "PyTorch", unsure = confidence.lowConfidenceWords),
        )
    }

    @Test
    fun `sound-alike is English only`() {
        val text = "deploy to cooper netteez now"
        assertEquals(text, VocabularyCorrection.apply(text, listOf("Kubernetes"), nearMisses = false))
    }

    @Test
    fun `snippet triggers are never joined`() {
        val text = "deploy to cooper netteez now"
        val start = text.indexOf("netteez")
        assertEquals(
            text,
            VocabularyCorrection.apply(
                text, listOf("Kubernetes"), isDictionaryWord = { it in dictionary },
                protectedRanges = listOf(start until start + "netteez".length),
            ),
        )
    }

    // Confidence

    @Test
    fun `no confidence means null`() {
        assertNull(RecognitionConfidence.UNREPORTED.add("hello", null).lowConfidenceWords)
        assertNull(RecognitionConfidence.UNREPORTED.lowConfidenceWords)
    }

    @Test
    fun `collects unsure words normalized`() {
        var confidence = RecognitionConfidence.UNREPORTED
        for ((word, probability) in listOf(" Deploy" to 0.97, " to" to 0.99, " cooper" to 0.41, " netties," to 0.32)) {
            confidence = confidence.add(word, probability)
        }
        assertEquals(setOf("cooper", "netties"), confidence.lowConfidenceWords)
    }

    @Test
    fun `sure of everything is an empty set`() {
        assertEquals(emptySet<String>(), RecognitionConfidence.UNREPORTED.add("yes", 0.95).lowConfidenceWords)
    }

    @Test
    fun `words are built from tokens`() {
        val tokens = listOf(
            RecognitionConfidence.Token(" deploy", -0.01f),
            RecognitionConfidence.Token(" cooper", -0.05f),
            RecognitionConfidence.Token(" net", -0.2f),
            RecognitionConfidence.Token("ties", -2.0f),
            RecognitionConfidence.Token(",", -0.01f),
        )
        // exp(-2) is 0.14: the minimum calls "netties" unsure; the geometric
        // mean of -0.2, -2.0 and -0.01 is exp(-0.74) = 0.48, unsure too.
        assertEquals(
            setOf("netties"),
            RecognitionConfidence.fromTokens(tokens, RecognitionConfidence.WordScore.MINIMUM).lowConfidenceWords,
        )
        assertEquals(
            setOf("netties"),
            RecognitionConfidence.fromTokens(tokens, RecognitionConfidence.WordScore.GEOMETRIC_MEAN).lowConfidenceWords,
        )
        val mild = listOf(RecognitionConfidence.Token(" ok", -0.3f))
        assertEquals(
            emptySet<String>(),
            RecognitionConfidence.fromTokens(mild, RecognitionConfidence.WordScore.GEOMETRIC_MEAN).lowConfidenceWords,
        )
    }

    @Test
    fun `sentence piece marks start words`() {
        val confidence = RecognitionConfidence.fromTokenLines(
            "-0.0100\t▁pie\n-1.5000\t▁tor\n-0.1000\tch\nnot a line\n",
            RecognitionConfidence.WordScore.MINIMUM,
        )
        assertEquals(setOf("torch"), confidence.lowConfidenceWords)
    }

    @Test
    fun `hyphenated words are the words correction sees`() {
        assertEquals(setOf("pie", "tot"), RecognitionConfidence.UNREPORTED.add(" pie-tot", 0.2).lowConfidenceWords)
    }

    @Test
    fun `merging keeps the rule`() {
        val first = RecognitionConfidence.UNREPORTED.add("pie", 0.2)
        val second = RecognitionConfidence.UNREPORTED.add("pie", 0.9).add("torch", 0.3)
        assertEquals(setOf("torch"), first.merging(second).lowConfidenceWords)
        assertNull(RecognitionConfidence.UNREPORTED.merging(RecognitionConfidence.UNREPORTED).lowConfidenceWords)
        assertEquals(setOf("pie"), RecognitionConfidence.UNREPORTED.merging(first).lowConfidenceWords)
    }
}
