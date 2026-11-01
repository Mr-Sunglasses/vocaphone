package com.vocahq.vocaphone.writing

import com.vocahq.vocaphone.grammar.GrammarFixtures
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rules' false-positive gate: on `tools/grammar-eval/clean_en.jsonl`, 300
 * correct casual and work lines, at most 2% may get a correctness suggestion.
 * Style suggestions (clarity, engagement, delivery) on correct text are not
 * errors and are not counted. Mirrors `WritingCleanTextTests.swift`.
 */
class WritingCleanTextTest {
    private fun lines(name: String) = File(GrammarFixtures.root, "../../tools/grammar-eval/$name").readLines()
        .filter { it.isNotBlank() }
        .map { JSONObject(it) }

    @Test
    fun correctTextGetsAlmostNoCorrectnessSuggestions() {
        val check = WritingCheck(WritingFixtures.rules, WritingFixtures.spelling)
        val cases = lines("clean_en.jsonl")
        val flagged = cases.mapNotNull { case ->
            val text = case.getString("input")
            val wrong = check.check(text).suggestions.filter { it.category == WritingCategory.CORRECTNESS }
            if (wrong.isEmpty()) null else "$text → ${wrong.joinToString { "${it.label} (${it.rule})" }}"
        }
        val rate = flagged.size.toDouble() / cases.size
        assertTrue("${flagged.size} of ${cases.size} correct lines flagged:\n" + flagged.joinToString("\n"), rate <= 0.02)
    }

    /** Every rule fix applied to the chat set must move a line toward what was meant, never away. */
    @Test
    fun ruleFixesOnTypedTextNeverMakeALineWorse() {
        val check = WritingCheck(WritingFixtures.rules, WritingFixtures.spelling)
        val worse = lines("typed_en.jsonl").mapNotNull { case ->
            val input = case.getString("input")
            val expected = case.getString("expected")
            var text = input
            for (s in check.check(input, options = WritingCheck.Options(categories = setOf(WritingCategory.CORRECTNESS))).suggestions.reversed()) {
                text = WritingCheck.apply(text, s) ?: text
            }
            val before = distance(input, expected)
            val after = distance(text, expected)
            if (after > before) "$input → $text (expected $expected)" else null
        }
        assertTrue("${worse.size} lines made worse:\n" + worse.joinToString("\n"), worse.isEmpty())
    }

    private fun distance(a: String, b: String): Int {
        val x = WritingText.tokenize(a).map { it.text }
        val y = WritingText.tokenize(b).map { it.text }
        val d = Array(x.size + 1) { IntArray(y.size + 1) }
        for (i in 0..x.size) d[i][0] = i
        for (j in 0..y.size) d[0][j] = j
        for (i in 1..x.size) for (j in 1..y.size) {
            d[i][j] = minOf(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + if (x[i - 1] == y[j - 1]) 0 else 1)
        }
        return d[x.size][y.size]
    }
}
