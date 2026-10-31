package com.vocahq.vocaphone.writing

/**
 * The grammar model's output as suggestions: a word diff of each sentence
 * against what the model made of it, each changed run classified into a kind
 * with a reason (an ERRANT-style classifier over the shared word tables, no
 * part-of-speech tagger). Mirrors `ModelEdits.swift`.
 */
internal class ModelEdits(private val rules: WritingRules) {
    /**
     * Suggestions for [sentence] (tokens `[sentence.first, sentence.last]` of
     * [tokens] in [text]) given the model's [corrected] text of it.
     */
    fun suggestions(
        text: String,
        tokens: List<WritingToken>,
        sentence: WritingSentence,
        corrected: String,
    ): List<WritingSuggestion> {
        val a = tokens.subList(sentence.first, sentence.last + 1)
        val b = WritingText.tokenize(corrected)
        if (a.map { it.text } == b.map { it.text }) return emptyList()
        val out = ArrayList<WritingSuggestion>()
        for (hunk in hunks(a, b)) {
            val inserted = if (hunk.bTo > hunk.bFrom) corrected.substring(b[hunk.bFrom].start, b[hunk.bTo - 1].end) else ""
            val from = sentence.first + hunk.aFrom
            val to = sentence.first + hunk.aTo
            val edit = WritingEdits.build(text, tokens, sentence.first, from, to, inserted)
            val removed = a.subList(hunk.aFrom, hunk.aTo)
            val added = b.subList(hunk.bFrom, hunk.bTo)
            val previous = if (hunk.aFrom > 0) a[hunk.aFrom - 1] else null
            val next = if (hunk.aTo < a.size) a[hunk.aTo] else null
            val atStart = hunk.aFrom == 0 || WritingText.isSentenceStart(tokens, sentence, from)
            val (kind, messageKey) = classify(removed, added, previous, next, atStart, endOfSentence = hunk.aFrom == a.size)
            val k = rules.kind(kind)
            val shownOriginal = edit.shownOriginal(text)
            val values = mapOf(
                "original" to shownOriginal,
                "replacement" to edit.replacement.trim(),
                "previous" to (previous?.text ?: ""),
                "next" to (next?.text ?: ""),
                "subject" to (previous?.takeIf { it.hasLetter }?.text ?: ""),
                "original_gloss" to (rules.glosses[WritingToken.normalize(shownOriginal)] ?: ""),
                "replacement_gloss" to (rules.glosses[WritingToken.normalize(edit.replacement.trim())] ?: ""),
            )
            val template = messageKey?.let { rules.messages[it] } ?: k.message
            out.add(
                WritingSuggestion(
                    start = edit.start,
                    end = edit.end,
                    original = text.substring(edit.start, edit.end),
                    replacement = edit.replacement,
                    markStart = edit.markStart,
                    markEnd = edit.markEnd,
                    kind = k.id,
                    category = k.category,
                    title = k.title,
                    message = WritingEdits.format(template, values),
                    mechanical = k.mechanical,
                    source = WritingSuggestion.Source.MODEL,
                ),
            )
        }
        return out
    }

    /** The kind and, where one fits better than the kind's own, a message key. */
    internal fun classify(
        removed: List<WritingToken>,
        added: List<WritingToken>,
        previous: WritingToken?,
        next: WritingToken?,
        atStart: Boolean,
        endOfSentence: Boolean,
    ): Pair<String, String?> {
        val all = removed + added
        if (all.isNotEmpty() && all.none { it.isWord }) {
            return "punctuation" to when {
                removed.isEmpty() && added.size == 1 -> when (added[0].text) {
                    "," -> "punctuation.add_comma"
                    "?" -> "punctuation.add_question"
                    "." -> if (endOfSentence) "punctuation.add_period" else "punctuation.add_other"
                    else -> "punctuation.add_other"
                }
                removed.isEmpty() -> "punctuation.add_other"
                added.isEmpty() -> "punctuation.remove"
                added.size == 1 && added[0].text == "?" -> "punctuation.add_question"
                else -> null
            }
        }
        if (removed.size == added.size && removed.isNotEmpty() &&
            removed.zip(added).all { (x, y) -> x.key == y.key }
        ) {
            return "capitalization" to when {
                removed.any { it.key == "i" || it.key.startsWith("i'") } -> "capitalization.i"
                atStart -> "capitalization.start"
                else -> null
            }
        }
        if (removed.size == 1 && added.size == 1 && removed[0].isWord && added[0].isWord) {
            return classifyWord(removed[0].key, added[0].key, previous)
        }
        if (removed.isEmpty()) {
            val word = added.singleOrNull()?.key
            return when {
                word != null && word in rules.articles -> "article" to "article.missing"
                word != null && (word in rules.classes["be"].orEmpty() || word in HELPERS) -> "missing_word" to "missing_word.verb"
                else -> "missing_word" to null
            }
        }
        if (added.isEmpty()) {
            val word = removed.singleOrNull()?.key
            return when {
                word != null && previous?.key == word -> "repeated_word" to null
                word != null && word in rules.articles -> "article" to "article.extra"
                else -> "extra_word" to "extra_word.remove"
            }
        }
        val joinedA = removed.joinToString("") { it.key }
        val joinedB = added.joinToString("") { it.key }
        if (joinedA.filter(Char::isLetterOrDigit) == joinedB.filter(Char::isLetterOrDigit)) return "spelling" to null
        return "word_choice" to null
    }

    private fun classifyWord(o: String, r: String, previous: WritingToken?): Pair<String, String?> {
        if (rules.confusable(o, r)) {
            val glossed = rules.glosses.containsKey(o) && rules.glosses.containsKey(r)
            return "confused_words" to if (glossed) "confused_words.gloss" else null
        }
        if (o.replace("'", "") == r.replace("'", "") && '\'' in r && '\'' !in o) return "apostrophe" to null
        if (o in rules.articles && r in rules.articles) {
            return "article" to when {
                o == "a" && r == "an" -> "article.a_to_an"
                o == "an" && r == "a" -> "article.an_to_a"
                else -> null
            }
        }
        val pronouns = rules.subjectPronouns + rules.objectPronouns
        if (o in pronouns && r in pronouns) {
            return "pronoun" to when {
                r in rules.subjectPronouns && o in rules.objectPronouns -> "pronoun.subject"
                r in rules.objectPronouns && o in rules.subjectPronouns -> "pronoun.object"
                else -> null
            }
        }
        if (o in rules.prepositions && r in rules.prepositions) return "preposition" to null
        if (AGREEMENT.any { o in it && r in it }) return agreement(previous)
        val verbs = rules.verbs
        val lemma = verbs.lemma(o)
        if (lemma != null && lemma == verbs.lemma(r)) {
            return if (o == verbs.third(r) || r == verbs.third(o)) agreement(previous) else "verb_form" to null
        }
        if (plural(o) == r || plural(r) == o) {
            // "two dog" is a noun; "the dogs barks" is a verb that disagrees with "dogs".
            val noun = previous == null || !previous.hasLetter || previous.key in rules.determiners ||
                previous.key in rules.prepositions
            return if (noun) "noun_number" to null else agreement(previous)
        }
        if (minOf(o.length, r.length) >= 3 && editDistance(o, r) <= 2) return "spelling" to null
        return "word_choice" to null
    }

    private fun agreement(previous: WritingToken?): Pair<String, String?> =
        "agreement" to if (previous?.hasLetter == true && previous.key !in rules.determiners) "agreement.subject" else null

    private fun plural(word: String): String = when {
        word.endsWith("y") && word.length > 1 && word[word.length - 2] !in "aeiou" -> word.dropLast(1) + "ies"
        word.endsWith("s") || word.endsWith("x") || word.endsWith("ch") || word.endsWith("sh") -> word + "es"
        else -> word + "s"
    }

    data class Hunk(val aFrom: Int, val aTo: Int, val bFrom: Int, val bTo: Int)

    /**
     * The changed runs, compared without case so a capital is its own
     * suggestion ("they was" → "They were" is "they" → "They" and "was" →
     * "were"), and a run of one-for-one swaps split into one per word.
     */
    private fun hunks(a: List<WritingToken>, b: List<WritingToken>): List<Hunk> {
        val out = ArrayList<Hunk>()
        var i = 0
        var j = 0
        fun caseOnly(toI: Int, toJ: Int) {
            while (i < toI && j < toJ) {
                if (a[i].text != b[j].text) out.add(Hunk(i, i + 1, j, j + 1))
                i++
                j++
            }
        }
        for (h in diff(a.map { it.key }, b.map { it.key })) {
            caseOnly(h.aFrom, h.bFrom)
            if (h.aTo - h.aFrom == h.bTo - h.bFrom && h.aTo - h.aFrom > 1) {
                for (k in 0 until h.aTo - h.aFrom) out.add(Hunk(h.aFrom + k, h.aFrom + k + 1, h.bFrom + k, h.bFrom + k + 1))
            } else {
                out.add(h)
            }
            i = h.aTo
            j = h.bTo
        }
        caseOnly(a.size, b.size)
        return out
    }

    companion object {
        private val HELPERS = setOf("have", "has", "had", "do", "does", "did", "will", "would", "can", "could", "should")
        private val AGREEMENT = listOf(
            setOf("is", "are", "am", "was", "were"),
            setOf("has", "have"),
            setOf("does", "do"),
            setOf("doesn't", "don't"),
            setOf("isn't", "aren't"),
            setOf("wasn't", "weren't"),
            setOf("hasn't", "haven't"),
        )

        /**
         * The most the longest-common-subsequence table may hold: a changed
         * middle of about 700 words each side. Past it, the middle is one hunk.
         */
        const val MAX_DIFF_CELLS = 500_000

        /**
         * The changed runs between [a] and [b], by longest common subsequence
         * of what is left once the shared start and end are set aside. Ties go
         * to deleting from [a] first, on both platforms. A middle too long to
         * compare in [MAX_DIFF_CELLS] comes back as one replaced run, so a long
         * pasted passage costs memory in proportion to its length, not its square.
         */
        fun diff(a: List<String>, b: List<String>): List<Hunk> {
            var prefix = 0
            while (prefix < a.size && prefix < b.size && a[prefix] == b[prefix]) prefix++
            var suffix = 0
            while (suffix < a.size - prefix && suffix < b.size - prefix && a[a.size - 1 - suffix] == b[b.size - 1 - suffix]) suffix++
            val n = a.size - prefix - suffix
            val m = b.size - prefix - suffix
            if (n == 0 && m == 0) return emptyList()
            if (n == 0 || m == 0 || n.toLong() * m > MAX_DIFF_CELLS) {
                return listOf(Hunk(prefix, prefix + n, prefix, prefix + m))
            }
            // lcs[i * (m + 1) + j]: the common subsequence of the middles from i and j on.
            val width = m + 1
            val lcs = IntArray((n + 1) * width)
            for (i in n - 1 downTo 0) {
                for (j in m - 1 downTo 0) {
                    lcs[i * width + j] = if (a[prefix + i] == b[prefix + j]) {
                        lcs[(i + 1) * width + j + 1] + 1
                    } else {
                        maxOf(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
                    }
                }
            }
            val hunks = ArrayList<Hunk>()
            var i = 0
            var j = 0
            var open: IntArray? = null
            fun close() {
                open?.let { hunks.add(Hunk(prefix + it[0], prefix + i, prefix + it[1], prefix + j)) }
                open = null
            }
            while (i < n || j < m) {
                when {
                    i < n && j < m && a[prefix + i] == b[prefix + j] -> {
                        close()
                        i++
                        j++
                    }
                    j >= m || (i < n && lcs[(i + 1) * width + j] >= lcs[i * width + j + 1]) -> {
                        if (open == null) open = intArrayOf(i, j)
                        i++
                    }
                    else -> {
                        if (open == null) open = intArrayOf(i, j)
                        j++
                    }
                }
            }
            close()
            return hunks
        }

        fun editDistance(a: String, b: String): Int {
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
