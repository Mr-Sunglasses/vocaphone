package com.vocahq.vocaphone.grammar

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rules the parity fixtures do not reach on their own: a model that
 * proposes something the guard must refuse. Mirrors GrammarTaggerTests.swift.
 */
class GrammarTaggerTest {
    private val labels = GrammarFixtures.labels
    private val index = labels.withIndex().associate { (i, label) -> label to i }

    /** A model that proposes [propose] for every word whose text matches, and KEEP elsewhere. */
    private fun model(vararg propose: Pair<String, String>, calls: MutableList<Int>? = null): GrammarTagger {
        val proposals = propose.toMap()
        lateinit var tagger: GrammarTagger
        tagger = GrammarFixtures.tagger { ids, rows ->
            calls?.add(rows.size)
            // Recover each word from its ids, the way the model would see it.
            val words = rows.indices.map { r ->
                val end = if (r + 1 < rows.size) rows[r + 1] else ids.size
                ids.copyOfRange(rows[r], end).toList()
            }
            Array(rows.size) { r ->
                val word = proposals.keys.firstOrNull { tagger.encodeWord(it).map(Int::toLong) == words[r] }
                FloatArray(labels.size).also { row ->
                    row[index.getValue(word?.let { proposals.getValue(it) } ?: "KEEP")] = 10f
                }
            }
        }
        return tagger
    }

    @Test
    fun protectedSpansNumbersAndNamesAreNeverChanged() {
        val tagger = model(
            "example.com" to "DELETE",
            "7:30" to "REPLACE_the",
            "42" to "DELETE",
            "Kevin" to "REPLACE_the",
            "iPhone" to "REPLACE_phone",
        )
        listOf(
            "Check example.com today.",
            "Meet at 7:30 please.",
            "I owe you 42 dollars.",
            "Tell Kevin hello.",
            "My iPhone died.",
        ).forEach { assertEquals(it, tagger.correct(it)) }
    }

    @Test
    fun customVocabularyIsNeverChanged() {
        // A replacement the guard would otherwise accept: one letter off.
        val tagger = model("tomorow" to "REPLACE_tomorrow")
        assertEquals("See you tomorrow.", tagger.correct("See you tomorow."))
        assertEquals("See you tomorow.", tagger.correct("See you tomorow.", setOf("Tomorow")))
    }

    @Test
    fun nonLatinWordsAndPunctuationTheModelMayNotTouch() {
        val tagger = model("café" to "REPLACE_cafe", "👍" to "DELETE")
        assertEquals("Meet at the café 👍", tagger.correct("Meet at the café 👍"))
        assertEquals("今天天气很好。", tagger.correct("今天天气很好。"))
    }

    @Test
    fun implausibleReplacementsAndAppendsAreRefused() {
        val tagger = model("cat" to "REPLACE_the", "home" to "APPEND_tomorrow", "noon" to "APPEND_very")
        assertEquals("The cat went home at noon.", tagger.correct("The cat went home at noon."))
    }

    @Test
    fun aPrepositionBeforeANumberOrNameStays() {
        val tagger = model("at" to "REPLACE_by")
        assertEquals("Meet at 5 pm.", tagger.correct("Meet at 5 pm."))
        assertEquals("Meet at Priya's.", tagger.correct("Meet at Priya's."))
    }

    @Test
    fun itStopsAfterThreePasses() {
        // A model that never settles: every pass appends another "the".
        val calls = ArrayList<Int>()
        val tagger = model("go" to "APPEND_the", calls = calls)
        tagger.correct("I go.")
        assertEquals(GrammarTagger.MAX_PASSES, calls.size)
    }

    @Test
    fun itStopsAsSoonAsAPassChangesNothing() {
        val calls = ArrayList<Int>()
        model(calls = calls).correct("Nothing to fix here.")
        assertEquals(1, calls.size)
    }

    @Test
    fun aPassedDeadlineLeavesTheRestOfTheTextAlone() {
        val tagger = model("don't" to "REPLACE_doesn't")
        val past = System.nanoTime() - 1
        assertEquals("He don't know. She don't care.", tagger.correct("He don't know. She don't care.", deadline = past))
        assertEquals("He doesn't know. She doesn't care.", tagger.correct("He don't know. She don't care."))
    }

    @Test
    fun textWithNoLettersComesBackAsItWas() {
        val tagger = model()
        listOf("", "...", "42", "👍 🎉").forEach { assertEquals(it, tagger.correct(it)) }
    }

    @Test
    fun longSentencesAreChunkedUnderTheModelsLimit() {
        val calls = ArrayList<Int>()
        val sentence = List(400) { "word" }.joinToString(" ") + "."
        val tagger = model(calls = calls)
        assertEquals(sentence, tagger.correct(sentence))
        assertTrue(calls.size >= 3)
    }

    @Test
    fun editDistanceIsLevenshtein() {
        assertEquals(0, GrammarTagger.editDistance("same", "same"))
        assertEquals(2, GrammarTagger.editDistance("recieve", "receive"))
        assertEquals(3, GrammarTagger.editDistance("kitten", "sitting"))
    }
}
