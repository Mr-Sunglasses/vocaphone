package com.vocahq.vocaphone.writing

import com.vocahq.vocaphone.grammar.GrammarFixtures
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `assets/grammar/writing_fixtures.json`, which `WritingCheckTests.swift`
 * reads too, so both keyboards and both apps flag the same words the same way.
 *
 * With `android/app/build/writing-record` present, this writes what the Kotlin
 * port computes to `build/writing_fixtures.json` instead of checking: review
 * it, then copy it over the fixture.
 */
class WritingCheckTest {
    private val fixtureFile = File(GrammarFixtures.root, "writing_fixtures.json")
    private val document = JSONObject(fixtureFile.readText())
    private val rules = WritingFixtures.rules
    private val check = WritingCheck(rules, WritingFixtures.spelling)
    private val recording = File("build/writing-record").exists()

    private fun cases(name: String) = document.getJSONArray(name).let { a -> List(a.length()) { a.getJSONObject(it) } }

    @Test
    fun everyRuleCompilesAndNamesAKnownKind() {
        rules.rules.forEach { assertTrue(it.id, it.kind in rules.kinds) }
        assertEquals(rules.rules.size, rules.rules.map { it.id }.toSet().size)
    }

    @Test
    fun fixtures() {
        val recorded = JSONObject(document.toString())
        tokenize(recorded)
        sentences(recorded)
        verbs(recorded)
        syllables(recorded)
        spelling(recorded)
        checks(recorded)
        rebase(recorded)
        apply(recorded)
        accept(recorded)
        if (recording) File("build/writing_fixtures.json").writeText(recorded.toString(1) + "\n")
    }

    private fun expect(case: JSONObject, out: JSONObject, key: String, actual: Any?) {
        val value = actual ?: JSONObject.NULL
        if (recording) {
            out.put(key, value)
            return
        }
        val label = case.optString("name", case.optString("text", case.optString("word"))) + " · " + key
        assertEquals(label, canonical(case.opt(key) ?: JSONObject.NULL), canonical(value))
    }

    /** JSON with its keys sorted, so two objects compare by content. */
    private fun canonical(value: Any?): String = when (value) {
        is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { "${JSONObject.quote(it)}:${canonical(value.get(it))}" }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        is String -> JSONObject.quote(value)
        null, JSONObject.NULL -> "null"
        else -> value.toString()
    }

    private fun section(recorded: JSONObject, name: String, block: (JSONObject, JSONObject) -> Unit) {
        val out = recorded.getJSONArray(name)
        cases(name).forEachIndexed { i, case -> block(case, out.getJSONObject(i)) }
    }

    private fun tokenize(recorded: JSONObject) = section(recorded, "tokenize") { case, out ->
        val tokens = WritingText.tokenize(case.getString("text"))
        expect(case, out, "tokens", JSONArray(tokens.map { JSONArray(listOf(it.text, it.start, it.end, it.isWord)) }))
    }

    private fun sentences(recorded: JSONObject) = section(recorded, "sentences") { case, out ->
        val text = case.getString("text")
        val s = WritingText.sentences(text, WritingText.tokenize(text))
        expect(case, out, "sentences", JSONArray(s.map { JSONArray(listOf(it.start, it.end, it.paragraph)) }))
    }

    private fun verbs(recorded: JSONObject) = section(recorded, "verbs") { case, out ->
        val verbs = rules.verbs
        val word = case.getString("word")
        val lemma = verbs.lemma(word)
        expect(case, out, "lemma", lemma)
        expect(case, out, "forms", lemma?.let { JSONArray(listOf(verbs.third(it), verbs.past(it), verbs.participle(it), verbs.ing(it))) })
        expect(case, out, "participle", verbs.isParticiple(word))
    }

    private fun syllables(recorded: JSONObject) = section(recorded, "syllables") { case, out ->
        expect(case, out, "count", WritingCheck.syllables(case.getString("word")))
    }

    private fun spelling(recorded: JSONObject) = section(recorded, "spelling") { case, out ->
        val word = case.getString("word")
        val dictionary = WritingFixtures.spelling
        expect(case, out, "known", dictionary.isKnown(word))
        val guess = dictionary.suggest(word.lowercase())
        expect(case, out, "guess", guess?.let { JSONArray(listOf(it.word, it.edits, it.score, it.sure)) })
    }

    private fun checks(recorded: JSONObject) = section(recorded, "check") { case, out ->
        val report = check.check(case.getString("text"), WritingFixtures.model(case), WritingFixtures.options(case))
        expect(case, out, "suggestions", JSONArray(report.suggestions.map(WritingFixtures::json)))
        expect(case, out, "tones", JSONArray(report.tones.map { it.id }))
        val s = report.stats
        expect(
            case, out, "stats",
            JSONArray(listOf(s.words, s.characters, s.sentences, s.readingSeconds, s.speakingSeconds, s.readability ?: JSONObject.NULL, s.score ?: JSONObject.NULL)),
        )
        expect(case, out, "modelPending", report.modelPending)
    }

    private fun rebase(recorded: JSONObject) = section(recorded, "rebase") { case, out ->
        val old = case.getString("old")
        val spans = case.getJSONArray("spans").let { a -> List(a.length()) { a.getJSONArray(it) } }
        val suggestions = spans.map { span -> WritingFixtures.bare(old, span.getInt(0), span.getInt(1)) }
        val rebased = WritingCheck.rebase(suggestions, old, case.getString("new"))
        expect(case, out, "expected", JSONArray(rebased.map { JSONArray(listOf(it.start, it.end)) }))
    }

    private fun apply(recorded: JSONObject) = section(recorded, "apply") { case, out ->
        val s = WritingFixtures.bare(case.getString("text"), case.getInt("start"), case.getInt("end"))
            .copy(original = case.getString("original"), replacement = case.getString("replacement"))
        expect(case, out, "expected", WritingCheck.apply(case.getString("text"), s))
    }

    /** Every suggestion accepted, last first: the spacing [WritingEdits.build] leaves behind. */
    private fun accept(recorded: JSONObject) = section(recorded, "accept") { case, out ->
        var text = case.getString("text")
        val report = check.check(text, WritingFixtures.model(case), WritingFixtures.options(case))
        for (s in report.suggestions.filter { it.isActionable }.sortedByDescending { it.start }) {
            text = WritingCheck.apply(text, s) ?: text
        }
        expect(case, out, "expected", text)
    }

    @Test
    fun diffSetsTheSharedEndsAsideAndBoundsTheMiddle() {
        val words = List(3000) { "w$it" }
        val one = words.toMutableList().also { it[1500] = "x" }
        assertEquals(listOf(ModelEdits.Hunk(1500, 1501, 1500, 1501)), ModelEdits.diff(words, one))
        // A middle past the table's budget is one replaced run, not a 2000 × 2000 table.
        val a = listOf("same") + List(2000) { "a$it" } + listOf("same")
        val b = listOf("same") + List(2000) { "b$it" } + listOf("same")
        assertEquals(listOf(ModelEdits.Hunk(1, 2001, 1, 2001)), ModelEdits.diff(a, b))
        // A short middle still aligns word by word.
        assertEquals(
            listOf(ModelEdits.Hunk(1, 2, 1, 1), ModelEdits.Hunk(3, 3, 2, 3)),
            ModelEdits.diff(listOf("a", "b", "c", "d"), listOf("a", "c", "x", "d")),
        )
    }
}

/** Shared by the writing tests: the rules file and the fixture's model and options. */
object WritingFixtures {
    val rules: WritingRules by lazy { WritingRules.parse(File(GrammarFixtures.root, "../keyboard/writing-rules.json").readText()) }

    /** The spelling dictionary both apps ship. */
    val spelling: WritingSpelling by lazy {
        WritingSpelling.parse(
            File(GrammarFixtures.root, "../keyboard/en-spelling.txt").readText(),
            File(GrammarFixtures.root, "../keyboard/en.txt").readText(),
        )
    }

    fun model(case: JSONObject): WritingCheck.Model? {
        if (!case.has("model")) return null
        val map = case.getJSONObject("model")
        return WritingCheck.Model { sentence -> if (!map.has(sentence)) sentence else if (map.isNull(sentence)) null else map.getString(sentence) }
    }

    fun options(case: JSONObject): WritingCheck.Options {
        val o = case.optJSONObject("options") ?: return WritingCheck.Options()
        val categories = o.optJSONArray("categories")?.let { a -> List(a.length()) { WritingCategory.of(a.getString(it)) }.toSet() }
        val keep = o.optJSONArray("keep")?.let { a -> List(a.length()) { a.getString(it) }.toSet() }
        val optIn = o.optJSONArray("optIn")?.let { a -> List(a.length()) { a.getString(it) }.toSet() }
        return WritingCheck.Options(
            categories = categories ?: WritingCategory.entries.toSet(),
            keep = keep ?: emptySet(),
            typed = o.optBoolean("typed", true),
            optIn = optIn ?: emptySet(),
        )
    }

    fun json(s: WritingSuggestion) = JSONObject().apply {
        put("start", s.start)
        put("end", s.end)
        put("original", s.original)
        put("replacement", s.replacement ?: JSONObject.NULL)
        put("mark", JSONArray(listOf(s.markStart, s.markEnd)))
        put("kind", s.kind)
        put("category", s.category.id)
        put("label", s.label)
        put("message", s.message)
        put("source", s.source.name.lowercase())
        put("rule", s.rule ?: JSONObject.NULL)
        put("mechanical", s.mechanical)
    }

    fun bare(text: String, start: Int, end: Int) = WritingSuggestion(
        start = start, end = end, original = text.substring(start, end), replacement = "x",
        markStart = start, markEnd = end, kind = "spelling", category = WritingCategory.CORRECTNESS,
        title = "Spelling", message = "", mechanical = true, source = WritingSuggestion.Source.MODEL,
    )
}
