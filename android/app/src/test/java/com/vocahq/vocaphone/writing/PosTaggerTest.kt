package com.vocahq.vocaphone.writing

import com.vocahq.vocaphone.grammar.GrammarFixtures
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `assets/grammar/pos_fixtures.json`, written by `tools/writing-tagger/fixtures.py`
 * from the reference tagger: the hash and every tag must match it exactly.
 * Mirrors `PosTaggerTests.swift`.
 */
class PosTaggerTest {
    private val document = JSONObject(File(GrammarFixtures.root, "pos_fixtures.json").readText())

    @Test
    fun hashesMatchTheReference() {
        val cases = document.getJSONArray("fnv")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            assertEquals(c.getString("text"), c.getString("hash"), java.lang.Long.toUnsignedString(PosTagger.fnv(c.getString("text")), 16).padStart(16, '0'))
        }
    }

    @Test
    fun everySentenceIsTaggedAsTheReferenceTagsIt() {
        val tagger = WritingFixtures.tagger
        val cases = document.getJSONArray("cases")
        assertTrue(cases.length() >= 20)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val words = c.getJSONArray("words").let { a -> List(a.length()) { a.getString(it) } }
            assertEquals(words, WritingText.tokenize(c.getString("text")).map { it.text })
            val tags = c.getJSONArray("tags").let { a -> List(a.length()) { a.getString(it) } }
            assertEquals(c.getString("text"), tags, tagger.tag(words))
        }
    }
}
