package com.vocahq.vocaphone.grammar

import java.io.File
import org.json.JSONArray
import org.json.JSONObject

/**
 * `assets/grammar/parity_fixtures.json` and the model's text files, read from
 * the repository. The same files back the Swift tests; both ports are checked
 * against `tools/grammar-eval/infer.py`'s output rather than against each other.
 */
internal object GrammarFixtures {
    val root: File = generateSequence(File("").absoluteFile) { it.parentFile }
        .map { File(it, "assets/grammar") }
        .first { File(it, "parity_fixtures.json").isFile }

    val document = JSONObject(File(root, "parity_fixtures.json").readText())

    val tokenizer: ByteLevelBpe by lazy { ByteLevelBpe.parse(File(root, "model-text/tokenizer.json").readText()) }

    val labels: List<String> by lazy { strings(JSONArray(File(root, "model-text/labels.json").readText())) }

    val pairs: List<String> by lazy { strings(JSONArray(File(root, "model-text/plausible_pairs.json").readText())) }

    fun strings(array: JSONArray): List<String> = List(array.length()) { array.getString(it) }

    fun longs(array: JSONArray): List<Long> = List(array.length()) { array.getLong(it) }

    fun ints(array: JSONArray): List<Int> = List(array.length()) { array.getInt(it) }

    /** Plays back the fixture's labels: each pass's ids map to the label per word the model chose. */
    fun replay(case: JSONObject): GrammarTagger.Logits {
        val byIds = HashMap<List<Long>, List<String>>()
        val sentences = case.getJSONArray("sentences")
        for (s in 0 until sentences.length()) {
            val passes = sentences.getJSONArray(s)
            for (p in 0 until passes.length()) {
                val pass = passes.getJSONObject(p)
                byIds[longs(pass.getJSONArray("ids"))] = strings(pass.getJSONArray("labels"))
            }
        }
        val index = labels.withIndex().associate { (i, label) -> label to i }
        return GrammarTagger.Logits { ids, rows ->
            val chosen = byIds[ids.toList()] ?: error("no fixture pass for ids ${ids.toList()}")
            Array(rows.size) { row ->
                FloatArray(labels.size).also { it[index.getValue(chosen[row])] = 10f }
            }
        }
    }

    fun tagger(logits: GrammarTagger.Logits) = GrammarTagger(tokenizer, labels, pairs, logits)
}
