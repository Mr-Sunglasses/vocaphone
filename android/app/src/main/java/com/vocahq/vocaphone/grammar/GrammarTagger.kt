package com.vocahq.vocaphone.grammar

import com.vocahq.vocaphone.core.ProtectedSpans

/**
 * The MindType v2.0 recipe, ported from `tools/grammar-eval/infer.py`.
 *
 * Pure Kotlin: the model is a [Logits] function, so everything here — word
 * split, alignment, KEEP bias, guard, edits and passes — is unit-tested against
 * `assets/grammar/parity_fixtures.json` without ONNX Runtime. The README beside
 * `infer.py` says why each rule exists; keep the three files in step.
 */
class GrammarTagger(
    private val tokenizer: ByteLevelBpe,
    private val labels: List<String>,
    plausiblePairs: Collection<String>,
    private val logits: Logits,
    private val keepBias: Float = KEEP_BIAS,
) {
    /** The model: label scores for the tokens at [rows] of [ids], one row each. */
    fun interface Logits {
        fun run(ids: LongArray, rows: IntArray): Array<FloatArray>
    }

    private val pairs: Set<Pair<String, String>> = plausiblePairs.mapNotNull { pair ->
        pair.split('→').takeIf { it.size == 2 }?.let { it[0] to it[1] }
    }.toSet()

    data class Word(val text: String, val space: String, val protected: Boolean = false)

    data class Decision(val word: String, val label: String, val chosen: String)

    data class Pass(val words: List<String>, val ids: List<Long>, val starts: List<Int>, val decisions: List<Decision>)

    /**
     * Corrects [text]. [vocabulary] words are never changed. [deadline] is a
     * `System.nanoTime()` value; a sentence that would start after it is left
     * as it was, so a long dictation keeps every sentence finished in time.
     * [bias] is added to KEEP's score: [KEEP_BIAS] is "Balanced",
     * [SURE_KEEP_BIAS] "Only sure fixes".
     */
    fun correct(
        text: String,
        vocabulary: Set<String> = emptySet(),
        deadline: Long = Long.MAX_VALUE,
        trace: MutableList<List<Pass>>? = null,
        bias: Float = keepBias,
    ): String {
        // Apostrophes compared straight, as the model reads them: a word saved
        // as "don't" also keeps "don’t".
        val lowered = vocabulary.mapTo(HashSet()) { it.lowercase().replace('’', '\'') }
        val masked = ProtectedSpans.mask(text)
        val spans = masked.tokens
        val out = StringBuilder()
        for ((lead, sentence) in splitSentences(masked.text)) {
            out.append(lead)
            if (System.nanoTime() > deadline) {
                out.append(sentence)
                continue
            }
            val passes = ArrayList<Pass>()
            out.append(correctSentence(sentence, lowered, spans, passes, deadline, bias))
            trace?.add(passes)
        }
        val restored = masked.restore(out.toString())
        return if (restored.any(Char::isLetter)) restored else text
    }

    internal fun correctSentence(
        sentence: String,
        vocabulary: Set<String>,
        spans: List<String>,
        passes: MutableList<Pass>,
        deadline: Long = Long.MAX_VALUE,
        bias: Float = keepBias,
    ): String {
        var words = splitWords(sentence)
        if (words.none { LATIN_WORD.containsMatchIn(it.text) }) return sentence
        repeat(MAX_PASSES) { pass ->
            // A later pass only refines the last one, so out of time it stops
            // with what the earlier passes already settled.
            if (pass > 0 && System.nanoTime() > deadline) return join(words, sentence)
            val chosen = MutableList(words.size) { "KEEP" }
            for (range in chunk(words, spans)) {
                // Out of time mid-sentence: the rest of this pass keeps its words.
                if (System.nanoTime() > deadline) break
                // One word longer than the model can read: leave it.
                if (range.last == range.first && oversized(words[range.first], spans)) continue
                val tagged = tag(words, range, vocabulary, spans, bias)
                passes.add(tagged)
                tagged.decisions.forEachIndexed { i, decision -> chosen[range.first + i] = decision.chosen }
            }
            val next = apply(words, chosen)
            val changed = next.map { it.text } != words.map { it.text }
            words = next
            if (!changed) return join(words, sentence)
        }
        return join(words, sentence)
    }

    private fun join(words: List<Word>, sentence: String): String =
        words.joinToString("") { it.space + it.text } + sentence.substring(sentence.trimEnd().length)

    // ── tokenization ───────────────────────────────────────────────────────

    /** What the model reads for a word: the hidden span, and straight apostrophes. */
    internal fun modelText(word: Word, spans: List<String>): String {
        PLACEHOLDER.matchEntire(word.text)?.let { m -> spans.getOrNull(m.groupValues[1].toInt())?.let { return it } }
        return word.text.replace('’', '\'')
    }

    /** Every word, the first included, as " " + word; the label is read at its first subtoken. */
    fun encodeWord(text: String): IntArray = tokenizer.encode(" $text")

    internal fun encode(texts: List<String>): Pair<LongArray, List<Int>> {
        val ids = arrayListOf(BOS_ID.toLong())
        val starts = ArrayList<Int>(texts.size)
        texts.forEach { text ->
            starts.add(ids.size)
            encodeWord(text).forEach { ids.add(it.toLong()) }
        }
        return ids.toLongArray() to starts
    }

    private fun oversized(word: Word, spans: List<String>): Boolean =
        encodeWord(modelText(word, spans)).size > MAX_TOKENS

    /**
     * Word ranges of at most [MAX_TOKENS] tokens each. A word that alone is
     * longer (a long URL fed as itself) gets a range of its own, which
     * [correctSentence] leaves alone rather than overflow the model's 160
     * positions.
     */
    private fun chunk(words: List<Word>, spans: List<String>): List<IntRange> {
        val chunks = ArrayList<IntRange>()
        var start = 0
        var tokens = 0
        words.forEachIndexed { i, word ->
            val count = encodeWord(modelText(word, spans)).size
            if (i > start && tokens + count > MAX_TOKENS) {
                chunks.add(start until i)
                start = i
                tokens = 0
            }
            if (count > MAX_TOKENS) {
                if (i > start) chunks.add(start until i)
                chunks.add(i..i)
                start = i + 1
                tokens = 0
            } else {
                tokens += count
            }
        }
        if (start < words.size) chunks.add(start until words.size)
        return chunks
    }

    // ── one pass ───────────────────────────────────────────────────────────

    /**
     * Runs the words in [range] through the model. The guard sees the whole
     * sentence, so a name or a preposition at a chunk's edge keeps the
     * protection it has anywhere else.
     */
    private fun tag(words: List<Word>, range: IntRange, vocabulary: Set<String>, spans: List<String>, bias: Float): Pass {
        val texts = words.slice(range).map { modelText(it, spans) }
        val (ids, starts) = encode(texts)
        val rows = logits.run(ids, starts.toIntArray())
        val decisions = starts.indices.map { i ->
            val row = rows[i]
            var best = 0
            var bestScore = row[0] + bias
            for (k in 1 until row.size) {
                if (row[k] > bestScore) {
                    bestScore = row[k]
                    best = k
                }
            }
            val label = labels[best]
            Decision(texts[i], label, allow(words, range.first + i, label, vocabulary))
        }
        return Pass(texts, ids.toList(), starts, decisions)
    }

    // ── the guard ──────────────────────────────────────────────────────────

    private fun frozen(words: List<Word>, i: Int, vocabulary: Set<String>): Boolean {
        val word = words[i]
        if (word.protected) return true
        if (!LATIN_WORD.matches(word.text)) return word.text !in PUNCT
        if (word.text.lowercase().replace('’', '\'') in vocabulary) return true
        if (word.text.drop(1).any(Char::isUpperCase)) return true
        if (word.text[0].isUpperCase() && !sentenceStart(words, i)) return !isPronounI(word.text)
        return false
    }

    internal fun allow(words: List<Word>, i: Int, label: String, vocabulary: Set<String>): String {
        if (label == "KEEP") return label
        if (frozen(words, i, vocabulary)) return "KEEP"
        val source = words[i].text
        val lower = source.lowercase()
        val next = words.getOrNull(i + 1)?.text.orEmpty()
        if (lower in PREPOSITIONS && !label.startsWith("APPEND_") && next.isNotEmpty() &&
            (next[0].isUpperCase() || next.any(Char::isDigit) || next[0] in GUARD_NEXT || PLACEHOLDER.matches(next))
        ) {
            return "KEEP"
        }
        if (label.startsWith("REPLACE_") && lower == "too" && (next.isEmpty() || next in PUNCT)) return "KEEP"
        return when {
            label == "DELETE" -> if (lower in DELETABLE) label else "KEEP"
            label.startsWith("\$CASE_") -> when {
                label == "\$CASE_CAP" && source.all { !it.isLetter() || it.isLowerCase() } &&
                    (sentenceStart(words, i) || source == "i") -> label
                label == "\$CASE_UP" && source == "i" -> label
                else -> "KEEP"
            }
            label.startsWith("APPEND_") -> {
                val added = label.removePrefix("APPEND_")
                if (added.lowercase() in APPENDABLE || added in PUNCT) label else "KEEP"
            }
            label.startsWith("REPLACE_") -> if (plausible(source, label.removePrefix("REPLACE_"))) label else "KEEP"
            else -> "KEEP"
        }
    }

    private fun plausible(source: String, target: String): Boolean {
        val a = source.lowercase().replace('’', '\'')
        val b = target.lowercase()
        if (a == b) return true
        if ((a to b) in pairs || (a to b) in CONFUSION) return true
        if (!LATIN_WORD.matches(target)) return false
        return minOf(a.length, b.length) >= 4 && editDistance(a, b) <= 2
    }

    // ── apply ──────────────────────────────────────────────────────────────

    internal fun apply(words: List<Word>, chosen: List<String>): List<Word> {
        val out = ArrayList<Word>(words.size + 2)
        words.forEachIndexed { i, word ->
            val label = chosen[i]
            when {
                label == "KEEP" -> out.add(word)
                label == "DELETE" -> Unit
                label == "\$CASE_CAP" -> out.add(Word(word.text.replaceFirstChar(Char::uppercaseChar), word.space))
                label == "\$CASE_LOW" -> out.add(Word(word.text.lowercase(), word.space))
                label == "\$CASE_UP" -> out.add(Word(word.text.uppercase(), word.space))
                label.startsWith("REPLACE_") -> {
                    var target = matchCase(word.text, label.removePrefix("REPLACE_"), sentenceStart(words, i))
                    if ('’' in word.text) target = target.replace('\'', '’')
                    out.add(Word(target, word.space))
                }
                label.startsWith("APPEND_") -> {
                    out.add(word)
                    val added = label.removePrefix("APPEND_")
                    out.add(Word(added, if (added in PUNCT || added.startsWith("'")) "" else " "))
                }
                else -> out.add(word)
            }
        }
        if (out.isNotEmpty() && words.isNotEmpty() && out[0].space != words[0].space) {
            out[0] = out[0].copy(space = words[0].space)
        }
        if (out.isNotEmpty() && words.isNotEmpty() && words[0].text.firstOrNull()?.isUpperCase() == true &&
            out[0].text.firstOrNull()?.isLowerCase() == true && !out[0].protected
        ) {
            out[0] = Word(out[0].text.replaceFirstChar(Char::uppercaseChar), out[0].space)
        }
        return out
    }

    companion object {
        /** "Balanced": the bias v2.0 was tuned for. */
        const val KEEP_BIAS = 3.0f
        /** "Only sure fixes": fewer, safer edits. */
        const val SURE_KEEP_BIAS = 4.0f
        const val MAX_PASSES = 3
        /** The position table holds 160; one goes to [BOS]. */
        const val MAX_TOKENS = 150
        const val BOS_ID = 1
        const val LABEL_COUNT = 15_000

        private val PLACEHOLDER = Regex("${ProtectedSpans.OPEN}(\\d+)${ProtectedSpans.CLOSE}")
        /**
         * Python's `str.isspace()` set, spelled out. `\\s` means ASCII
         * whitespace on the JVM and Unicode whitespace on Android, and the flag
         * that would make them agree, `(?U)`, throws on Android. An explicit
         * class reads the same everywhere, and the same as `infer.py`.
         */
        private const val SPACE = "\\t\\n\\u000B\\u000C\\r\\u001C-\\u001F \\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000"
        private val WORD = Regex("${ProtectedSpans.OPEN}\\d+${ProtectedSpans.CLOSE}|[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)*|[^$SPACE]")
        private val LATIN_WORD = Regex("[A-Za-z]+(?:['’][A-Za-z]+)*")
        private val SENTENCE_END = Regex("(?<=[.!?])[$SPACE]+")
        private val PUNCT = setOf(".", ",", "!", "?", ";", ":")
        private val GUARD_NEXT = setOf('$', '£', '€', '#', '@')
        private val DELETABLE = setOf("more", "most", "of", "the", "a", "an", "to", "is", "are")
        private val APPENDABLE = "a an the to is are am was were be have has 's 'm 're 've 'll 'd".split(' ').toSet()
        private val PREPOSITIONS = (
            "about above across after against along around at before behind below beside between by down " +
                "during for from in inside into near of off on onto out over past since through till to toward " +
                "towards under until up upon with within without"
            ).split(' ').toSet()
        private val CONFUSION_SETS = listOf(
            setOf("a", "an", "the"),
            setOf("is", "are", "am", "was", "were", "be", "been", "being"),
            setOf("has", "have", "had"),
            setOf("do", "does", "did", "done"),
            setOf("don't", "doesn't", "didn't"),
            setOf("isn't", "aren't", "wasn't", "weren't"),
            setOf("hasn't", "haven't"),
            setOf("their", "there", "they're"),
            setOf("its", "it's"),
            setOf("your", "you're"),
            setOf("whose", "who's"),
            setOf("were", "we're", "where"),
            setOf("then", "than"),
            setOf("to", "too", "two"),
            setOf("of", "have"),
            setOf("lose", "loose"),
            setOf("affect", "effect"),
            setOf("accept", "except"),
            setOf("fewer", "less"),
            setOf("lie", "lay", "lying", "laying"),
            setOf("me", "i"),
            setOf("him", "he"),
            setOf("her", "she"),
            setOf("them", "they"),
            setOf("us", "we"),
        )
        private val CONFUSION: Set<Pair<String, String>> =
            CONFUSION_SETS.flatMap { set -> set.flatMap { a -> set.filter { it != a }.map { a to it } } }.toSet()

        internal fun splitWords(sentence: String): List<Word> {
            var position = 0
            return WORD.findAll(sentence).map { m ->
                Word(m.value, sentence.substring(position, m.range.first), PLACEHOLDER.matches(m.value))
                    .also { position = m.range.last + 1 }
            }.toList()
        }

        /** (whitespace before, sentence) pairs that rejoin to [text]. */
        internal fun splitSentences(text: String): List<Pair<String, String>> {
            val out = ArrayList<Pair<String, String>>()
            var lead = ""
            var start = 0
            SENTENCE_END.findAll(text).forEach { m ->
                out.add(lead to text.substring(start, m.range.first))
                lead = m.value
                start = m.range.last + 1
            }
            out.add(lead to text.substring(start))
            return out
        }

        private fun sentenceStart(words: List<Word>, i: Int): Boolean {
            var j = i - 1
            while (j >= 0 && words[j].text in setOf("\"", "“", "'", "(")) j--
            return j < 0 || words[j].text in setOf(".", "!", "?")
        }

        private fun isPronounI(text: String) = text == "I" || text.startsWith("I'") || text.startsWith("I’")

        private fun matchCase(source: String, target: String, atStart: Boolean): String = when {
            source.length > 1 && source.all { !it.isLetter() || it.isUpperCase() } -> target.uppercase()
            source[0].isUpperCase() && (atStart || isPronounI(source)) -> target.replaceFirstChar(Char::uppercaseChar)
            source[0].isLowerCase() && target.firstOrNull()?.isUpperCase() == true && !isPronounI(target) ->
                target.replaceFirstChar(Char::lowercaseChar)
            else -> target
        }

        internal fun editDistance(a: String, b: String): Int {
            var previous = IntArray(b.length + 1) { it }
            for (i in 1..a.length) {
                val current = IntArray(b.length + 1)
                current[0] = i
                for (j in 1..b.length) {
                    current[j] = minOf(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
                }
                previous = current
            }
            return previous[b.length]
        }
    }
}
