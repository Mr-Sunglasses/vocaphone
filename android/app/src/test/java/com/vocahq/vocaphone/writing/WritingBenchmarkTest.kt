package com.vocahq.vocaphone.writing

import com.vocahq.vocaphone.grammar.GrammarFixtures
import com.vocahq.vocaphone.grammar.GrammarTagger
import com.vocahq.vocaphone.local.GrammarModelCatalog
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * How much of what Grammarly would catch Writing check catches: the whole
 * check, rules and grammar model together, on the sets in `tools/grammar-eval/`,
 * every suggestion in the default groups (correctness and clarity) accepted.
 *
 * `results.md` and friends score the model alone; this scores what the user
 * gets. ONNX Runtime does not run here, so the model's text for each sentence
 * comes from `tools/grammar-eval/answers.json` (`answers.py` writes it). The
 * configurations are what each surface runs:
 *
 * - `rules`: the rules, the spelling dictionary and the agreement checks, no model. The iOS
 *   keyboard whenever the app is not running, and the F-Droid build.
 * - `balanced`: the model at the KEEP bias that "Check while typing", the
 *   system spell checker and dictation use.
 * - `thorough`: the model at the KEEP bias of a check the user asked for, the
 *   keyboard's Writing check button and the Writing check screen.
 *
 * The full report goes to `build/writing-benchmark.md`. [FLOORS] fails the test
 * when a change catches less, and [CEILINGS] when it flags more correct text;
 * raise a floor when a change earns it. [answersAreCurrent] fails when the
 * answers were made from another model, `infer.py` or bias than the app's.
 */
class WritingBenchmarkTest {
    private val root = File(GrammarFixtures.root, "../../tools/grammar-eval")
    private val check = WritingCheck(WritingFixtures.rules, WritingFixtures.spelling, WritingFixtures.tagger)
    private val answers = JSONObject(File(root, "answers.json").readText())
    private val asked = answers.getJSONArray("sentences").let { a -> List(a.length()) { a.getString(it) } }.toHashSet()

    private data class Case(val input: String, val expected: String, val type: String?)

    private data class Score(
        val errors: Int,
        val exact: Int,
        val flagged: Int,
        val worse: Int,
        val clean: Int,
        val falseAlarms: Int,
        val misses: List<String>,
        val alarms: List<String>,
        val byType: Map<String, Pair<Int, Int>>,
    ) {
        fun exactRate() = if (errors == 0) 0.0 else exact.toDouble() / errors
        fun falseAlarmRate() = if (clean == 0) 0.0 else falseAlarms.toDouble() / clean
    }

    private fun cases(name: String): List<Case> = File(root, name).readLines().filter { it.isNotBlank() }.map {
        val o = JSONObject(it)
        Case(o.getString("input"), o.getString("expected"), o.optString("type").takeIf { t -> t.isNotEmpty() })
    }

    private fun model(tier: String?): WritingCheck.Model? {
        if (tier == null) return null
        val changed = answers.getJSONObject(tier)
        return WritingCheck.Model { sentence ->
            check(sentence in asked) { "answers.json has no answer for \"$sentence\": run tools/grammar-eval/answers.py" }
            if (changed.has(sentence)) changed.getString(sentence) else sentence
        }
    }

    @Test
    fun answersAreCurrent() {
        val from = answers.getJSONObject("madeFrom")
        val stale = "tools/grammar-eval/answers.json is stale: rerun answers.py"
        val model = from.getJSONObject("model").let { m -> m.keys().asSequence().associateWith { m.getString(it) } }
        assertEquals(
            "$stale (the pinned grammar model changed)",
            GrammarModelCatalog.tagger.files.associate { it.path.substringAfterLast('/') to it.sha256 },
            model,
        )
        assertEquals("$stale (infer.py changed)", sha256(File(root, "infer.py")), from.getString("infer.py"))
        val bias = from.getJSONObject("bias")
        assertEquals("$stale (a tier's bias changed)", TIER_BIAS.keys, bias.keys().asSequence().toSet())
        TIER_BIAS.forEach { (tier, value) -> assertEquals("$stale ($tier bias)", value.toDouble(), bias.getDouble(tier), 0.0) }
    }

    private fun sha256(file: File): String =
        MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

    /** [input] with every actionable suggestion in the default groups accepted, last first. */
    private fun accepted(input: String, model: WritingCheck.Model?): Pair<String, List<WritingSuggestion>> {
        val report = check.check(input, model, OPTIONS)
        var text = input
        for (s in report.suggestions.filter { it.isActionable }.sortedByDescending { it.start }) {
            text = WritingCheck.apply(text, s) ?: text
        }
        return text to report.suggestions
    }

    private fun score(cases: List<Case>, model: WritingCheck.Model?): Score {
        var errors = 0
        var exact = 0
        var flagged = 0
        var worse = 0
        var clean = 0
        var falseAlarms = 0
        val misses = ArrayList<String>()
        val alarms = ArrayList<String>()
        val byType = LinkedHashMap<String, Pair<Int, Int>>()
        for (case in cases) {
            val (out, suggestions) = accepted(case.input, model)
            if (case.input == case.expected) {
                clean++
                val wrong = suggestions.filter { it.category == WritingCategory.CORRECTNESS }
                if (wrong.isNotEmpty()) {
                    falseAlarms++
                    alarms += "- `${case.input}`: ${wrong.joinToString { "${it.label} (${it.rule ?: it.source.name.lowercase()})" }}"
                }
                continue
            }
            errors++
            if (suggestions.any { it.category == WritingCategory.CORRECTNESS || it.category == WritingCategory.CLARITY }) flagged++
            val hit = out == case.expected
            if (hit) exact++ else misses += "- `${case.input}` → `$out` (expected `${case.expected}`)"
            if (!hit && distance(out, case.expected) > distance(case.input, case.expected)) worse++
            case.type?.let { t ->
                val (n, k) = byType[t] ?: (0 to 0)
                byType[t] = (n + 1) to (k + if (hit) 1 else 0)
            }
        }
        return Score(errors, exact, flagged, worse, clean, falseAlarms, misses, alarms, byType)
    }

    @Test
    fun benchmark() {
        val results = LinkedHashMap<String, Score>()
        for (set in SETS) {
            val cases = cases(set)
            for ((name, tier) in CONFIGURATIONS) results["${set.removeSuffix("_en.jsonl")} · $name"] = score(cases, model(tier))
        }
        val report = StringBuilder()
        report.append("# Writing check benchmark\n\nGenerated by `WritingBenchmarkTest`. Every suggestion in the default groups ")
        report.append("(correctness, clarity) accepted.\n\n")
        report.append("| Set · configuration | Errors fixed exactly | Errors flagged | Made worse | Correct lines flagged |\n")
        report.append("|---|---|---|---|---|\n")
        for ((key, s) in results) {
            report.append("| $key | ${cell(s.exact, s.errors)} | ${cell(s.flagged, s.errors)} | ${cell(s.worse, s.errors)} | ${cell(s.falseAlarms, s.clean)} |\n")
        }
        for ((key, s) in results) {
            if (s.byType.isNotEmpty()) {
                report.append("\n## $key, by type\n\n| Type | Fixed exactly |\n|---|---|\n")
                s.byType.forEach { (t, v) -> report.append("| $t | ${cell(v.second, v.first)} |\n") }
            }
        }
        for ((key, s) in results) {
            if (s.alarms.isNotEmpty()) report.append("\n## $key: correct lines flagged (${s.alarms.size})\n\n").append(s.alarms.joinToString("\n")).append("\n")
            if (s.misses.isNotEmpty()) report.append("\n## $key: not fixed exactly (${s.misses.size})\n\n").append(s.misses.joinToString("\n")).append("\n")
        }
        File("build/writing-benchmark.md").apply { parentFile?.mkdirs() }.writeText(report.toString())

        val failures = ArrayList<String>()
        FLOORS.forEach { (key, floor) ->
            val s = results.getValue(key)
            if (s.exactRate() + FLOOR_ROUNDING < floor) failures += "$key fixes ${pct(s.exactRate())} exactly, below its floor of ${pct(floor)}"
        }
        CEILINGS.forEach { (key, ceiling) ->
            val s = results.getValue(key)
            if (s.falseAlarmRate() > ceiling + 1e-9) failures += "$key flags ${pct(s.falseAlarmRate())} of correct lines, above its ceiling of ${pct(ceiling)}"
        }
        assertTrue(failures.joinToString("\n") + "\n\nSee android/app/build/writing-benchmark.md", failures.isEmpty())
    }

    private fun cell(k: Int, n: Int) = if (n == 0) "–" else "$k / $n (${pct(k.toDouble() / n)})"

    private fun pct(x: Double) = String.format(Locale.ROOT, "%.1f%%", x * 100)

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

    private companion object {
        val OPTIONS = WritingCheck.Options(categories = setOf(WritingCategory.CORRECTNESS, WritingCategory.CLARITY), typed = true)

        val SETS = listOf(
            "everyday_en.jsonl",
            "heldout_en.jsonl",
            "heldout_clean_en.jsonl",
            "typed_en.jsonl",
            "dictation_en.jsonl",
            "clean_en.jsonl",
        )

        /** Configuration name → the answers.json tier the model reads, or null for none. */
        val CONFIGURATIONS = linkedMapOf<String, String?>("rules" to null, "balanced" to "balanced", "thorough" to "thorough")

        /** Each answers.json tier's KEEP bias, which `answers.py` must have used. */
        val TIER_BIAS = mapOf("balanced" to GrammarTagger.KEEP_BIAS, "thorough" to GrammarTagger.THOROUGH_KEEP_BIAS)

        /** Floors are written to a tenth of a percent, rounded: 133 of 163 is 81.595%, written 0.816. */
        const val FLOOR_ROUNDING = 0.0005

        /** Share of error lines that must come out exactly as meant: what each configuration reached. */
        val FLOORS = mapOf(
            "everyday · rules" to 0.728,
            "everyday · balanced" to 0.828,
            "everyday · thorough" to 0.842,
            "heldout · rules" to 0.680,
            "heldout · balanced" to 0.760,
            "heldout · thorough" to 0.800,
            "typed · rules" to 0.673,
            "typed · balanced" to 0.797,
            "typed · thorough" to 0.823,
            "dictation · rules" to 0.650,
            "dictation · balanced" to 0.852,
            "dictation · thorough" to 0.865,
        )

        /** Share of correct lines that may get a correctness suggestion. */
        val CEILINGS = mapOf(
            "heldout_clean · rules" to 0.02,
            "heldout_clean · balanced" to 0.02,
            "heldout_clean · thorough" to 0.02,
            "clean · rules" to 0.02,
            "clean · balanced" to 0.02,
            "clean · thorough" to 0.02,
            "dictation · rules" to 0.02,
            "dictation · balanced" to 0.02,
            "dictation · thorough" to 0.02,
        )
    }
}
