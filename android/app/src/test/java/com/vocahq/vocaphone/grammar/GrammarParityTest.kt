package com.vocahq.vocaphone.grammar

import com.vocahq.vocaphone.local.GrammarModelCatalog
import com.vocahq.vocaphone.local.LocalModelIntegrity
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors ios/VocaPhoneTests/GrammarParityTests.swift. */
class GrammarParityTest {
    private val fixtures = GrammarFixtures

    @Test
    fun testCopiesOfTheModelTextMatchThePins() {
        listOf("tokenizer.json", "labels.json", "plausible_pairs.json").forEach { name ->
            val pinned = GrammarModelCatalog.tagger.files.first { it.path == "onnx/$name" }
            val copy = File(fixtures.root, "model-text/$name")
            assertEquals(name, pinned.sha256, LocalModelIntegrity.sha256(copy))
        }
    }

    @Test
    fun fixturesWereMadeFromThePinnedModel() {
        val sha = fixtures.document.getJSONObject("model").getJSONObject("sha256")
        GrammarModelCatalog.tagger.files.forEach { pinned ->
            assertEquals(pinned.path, pinned.sha256, sha.getString(pinned.path))
        }
    }

    @Test
    fun tokenizerIdsMatchExactly() {
        val words = fixtures.document.getJSONArray("tokenizer")
        for (i in 0 until words.length()) {
            val entry = words.getJSONObject(i)
            val word = entry.getString("word")
            val expected = fixtures.ints(entry.getJSONArray("ids"))
            val tagger = fixtures.tagger { _, rows -> Array(rows.size) { FloatArray(1) } }
            assertEquals("“$word”", expected, tagger.encodeWord(word).toList())
        }
    }

    @Test
    fun everyPassEncodesTheSameIdsAndStarts() {
        val tagger = fixtures.tagger { _, rows -> Array(rows.size) { FloatArray(1) } }
        val cases = fixtures.document.getJSONArray("cases")
        for (c in 0 until cases.length()) {
            val sentences = cases.getJSONObject(c).getJSONArray("sentences")
            for (s in 0 until sentences.length()) {
                val passes = sentences.getJSONArray(s)
                for (p in 0 until passes.length()) {
                    val pass = passes.getJSONObject(p)
                    val (ids, starts) = tagger.encode(fixtures.strings(pass.getJSONArray("words")))
                    assertEquals(fixtures.longs(pass.getJSONArray("ids")), ids.toList())
                    assertEquals(fixtures.ints(pass.getJSONArray("starts")), starts)
                }
            }
        }
    }

    /** Given the model's labels, the guard, the edits and the passes reach the reference output. */
    @Test
    fun guardEditsAndPassesReachTheReferenceOutput() {
        val cases = fixtures.document.getJSONArray("cases")
        for (c in 0 until cases.length()) {
            val case = cases.getJSONObject(c)
            val input = case.getString("input")
            val trace = ArrayList<List<GrammarTagger.Pass>>()
            val output = fixtures.tagger(fixtures.replay(case)).correct(
                input,
                fixtures.strings(case.getJSONArray("vocabulary")).toSet(),
                trace = trace,
            )
            assertEquals("“$input”", case.getString("output"), output)
            val sentences = case.getJSONArray("sentences")
            assertEquals("“$input” sentences", sentences.length(), trace.size)
            trace.forEachIndexed { s, passes ->
                val expected = sentences.getJSONArray(s)
                assertEquals("“$input” passes", expected.length(), passes.size)
                passes.forEachIndexed { p, pass ->
                    val chosen = fixtures.strings(expected.getJSONObject(p).getJSONArray("chosen"))
                    assertEquals("“$input” pass $p", chosen, pass.decisions.map { it.chosen })
                }
            }
        }
        assertTrue(cases.length() >= 40)
    }
}
