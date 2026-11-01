package com.vocahq.vocaphone.writing

import com.vocahq.vocaphone.core.ProtectedSpans
import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * Writing check (English): the whole Grammarly-style pass over a piece of
 * text, on the phone. Pure, so every decision is unit-tested against
 * `assets/grammar/writing_fixtures.json`, which `WritingCheck.swift` reads too.
 *
 * Two sources of suggestions meet here. The rules in `writing-rules.json`
 * run anywhere, the iOS keyboard extension and the F-Droid build included.
 * The grammar model runs where ONNX Runtime does and arrives as [Model]: a
 * sentence in, the model's corrected sentence out, or null while it loads.
 * Nothing leaves the device.
 */
class WritingCheck(val rules: WritingRules) {
    /** One sentence in, the model's correction out; null while it is not ready. */
    fun interface Model {
        fun correct(sentence: String): String?
    }

    data class Options(
        val categories: Set<WritingCategory> = WritingCategory.entries.toSet(),
        /** The user's own words (custom vocabulary, snippet triggers): never flagged. */
        val keep: Set<String> = emptySet(),
        /**
         * Typed text: a full stop the model adds where the text stops, and a
         * capital on a sentence typed in lower case on purpose, are not offered.
         */
        val typed: Boolean = true,
        /** Rules the user turned on that are off by default, by their `optIn` name: "serial_comma". */
        val optIn: Set<String> = emptySet(),
    )

    data class Tone(val id: String, val label: String, val emoji: String, val score: Int)

    data class Stats(
        val words: Int,
        val characters: Int,
        val sentences: Int,
        val readingSeconds: Int,
        val speakingSeconds: Int,
        /** Flesch reading ease, 0–100; null without a sentence to measure. */
        val readability: Int?,
        val readabilityLabel: String?,
        /** 100 less a weighted count of issues per 100 words; null for empty text. */
        val score: Int?,
    )

    data class Report(
        val text: String,
        val suggestions: List<WritingSuggestion>,
        val tones: List<Tone>,
        val stats: Stats,
        /** A sentence the model was asked about came back null: it is still loading. */
        val modelPending: Boolean,
    )

    private val modelEdits = ModelEdits(rules)

    fun check(text: String, model: Model? = null, options: Options = Options()): Report {
        val tokens = WritingText.tokenize(text)
        val sentences = WritingText.sentences(text, tokens)
        val protected = ProtectedSpans.ranges(text)
        val keep = options.keep.mapTo(HashSet(), WritingToken::normalize)
        val found = ArrayList<WritingSuggestion>()
        var pending = false

        for (sentence in sentences) found += ruleSuggestions(text, tokens, sentence, protected, keep, options)
        if (model != null) {
            for (sentence in sentences) {
                val words = tokens.subList(sentence.first, sentence.last + 1)
                if (words.none { it.hasLetter && it.text.any { c -> c in 'a'..'z' || c in 'A'..'Z' } }) continue
                val corrected = model.correct(text.substring(sentence.start, sentence.end))
                if (corrected == null) {
                    pending = true
                    continue
                }
                found += modelEdits.suggestions(text, tokens, sentence, corrected)
                    .filter { s -> keep.none { it in wordsIn(s.original) } }
            }
        }
        found += longSentences(text, tokens, sentences)
        found += overusedWords(tokens, sentences, keep)

        val lowercaseStyle = text.firstOrNull { it.isLetter() }?.isLowerCase() == true
        val starts = sentences.mapTo(HashSet()) { s ->
            (s.first..s.last).first { WritingText.isSentenceStart(tokens, s, it) && tokens[it].isWord || it == s.last }
                .let { tokens[it].start }
        }
        val kept = found.filter { it.category in options.categories }
            .filter { !options.typed || offeredOnTypedText(it, text, lowercaseStyle, starts) }
        val merged = merge(kept, text)
        return Report(text, merged, tones(text, tokens), stats(text, tokens, sentences, merged), pending)
    }

    // ── rules ──────────────────────────────────────────────────────────────

    private fun ruleSuggestions(
        text: String,
        tokens: List<WritingToken>,
        sentence: WritingSentence,
        protected: List<IntRange>,
        keep: Set<String>,
        options: Options,
    ): List<WritingSuggestion> {
        val out = ArrayList<WritingSuggestion>()
        // Tokens a suggestion already changes. A later rule may still match
        // across them ("didnt went" is both "didnt" → "didn't" and "went" →
        // "go"), but may not change them a second time.
        val claimed = HashSet<Int>()
        for (i in sentence.first..sentence.last) {
            val start = WritingText.isSentenceStart(tokens, sentence, i)
            for (index in candidates(tokens[i])) {
                val rule = rules.rules[index]
                // A rule the user turned off must not take its words from one
                // they kept: "could" is hedging, and "could helps" still needs "help".
                if (rules.kind(rule.kind).category !in options.categories) continue
                if (rule.optIn != null && rule.optIn !in options.optIn) continue
                val count = rule.match(tokens, sentence, i, rules, start)
                if (count == 0) continue
                val matched = tokens.subList(i, i + count)
                if (matched.any { t -> protected.any { t.start <= it.last && it.first < t.end } }) continue
                val found = ruleSuggestion(text, tokens, sentence, rule, i, matched, keep) ?: continue
                if (!found.suggestion.isActionable) {
                    out.add(found.suggestion)
                    continue
                }
                if ((found.from until found.to).any { it in claimed }) continue
                out.add(found.suggestion)
                for (k in found.from until found.to) claimed.add(k)
                // Once this token has changed, no other rule may start here.
                if (i in found.from until found.to) break
            }
        }
        return out
    }

    /** A rule's suggestion and the tokens `[from, to)` it changes. */
    private class Found(val suggestion: WritingSuggestion, val from: Int, val to: Int)

    /** The rules that could start at [token], in the file's order. */
    private fun candidates(token: WritingToken): IntArray {
        val a = rules.rulesByFirstWord[token.key] ?: return rules.rulesStartingWithClass
        val b = rules.rulesStartingWithClass
        val out = IntArray(a.size + b.size)
        var i = 0
        var j = 0
        var k = 0
        while (i < a.size || j < b.size) {
            out[k++] = if (j >= b.size || (i < a.size && a[i] < b[j])) a[i++] else b[j++]
        }
        return out
    }

    private fun ruleSuggestion(
        text: String,
        tokens: List<WritingToken>,
        sentence: WritingSentence,
        rule: WritingRule,
        index: Int,
        matched: List<WritingToken>,
        keep: Set<String>,
    ): Found? {
        val kind = rules.kind(rule.kind)
        val values = HashMap<String, String>()
        matched.forEachIndexed { i, t -> values["${i + 1}"] = t.text }
        val expanded = rule.expand(matched, rules)
        if (expanded == null) {
            val first = matched.first()
            val last = matched.last()
            values["original"] = text.substring(first.start, last.end)
            val info = WritingSuggestion(
                start = first.start, end = last.end, original = text.substring(first.start, last.end),
                replacement = null, markStart = first.start, markEnd = last.end,
                kind = kind.id, category = kind.category, title = kind.title,
                message = WritingEdits.format(template(rule, kind), values),
                mechanical = kind.mechanical, source = WritingSuggestion.Source.RULE, rule = rule.id,
            )
            return Found(info, index, index + matched.size)
        }
        // Narrow to the tokens that change: "rather then" → "rather than" is
        // "then" → "than". Case counts only for a capitalization rule.
        val replacementTokens = WritingText.tokenize(expanded)
        val exact = kind.id == "capitalization"
        val m = matched.map { if (exact) it.text else it.key }
        val r = replacementTokens.map { if (exact) it.text else it.key }
        var pre = 0
        while (pre < m.size && pre < r.size && m[pre] == r[pre]) pre++
        var suf = 0
        while (suf < m.size - pre && suf < r.size - pre && m[m.size - 1 - suf] == r[r.size - 1 - suf]) suf++
        if (pre == m.size && pre == r.size) return null
        val capitalize = matched[0].text.firstOrNull()?.isUpperCase() == true
        // Dropping a sentence's first words: the word that now starts it takes the capital.
        if (pre == 0 && capitalize && r.size == suf && suf > 0) suf--
        values["match"] = text.substring(matched.first().start, matched.last().end)
        values["result"] = if (capitalize) expanded.replaceFirstChar(Char::uppercaseChar) else expanded
        val from = index + pre
        val to = index + m.size - suf
        if (tokens.subList(from, to).any { it.key in keep }) return null
        var inserted = if (r.size - suf > pre) expanded.substring(replacementTokens[pre].start, replacementTokens[r.size - 1 - suf].end) else ""
        if (pre == 0 && capitalize && inserted.firstOrNull()?.isLowerCase() == true) {
            inserted = inserted.replaceFirstChar(Char::uppercaseChar)
        }
        val edit = WritingEdits.build(text, tokens, sentence.first, from, to, inserted)
        val original = text.substring(edit.start, edit.end)
        values["original"] = edit.shownOriginal(text)
        values["replacement"] = edit.replacement.trim()
        values["previous"] = if (from > sentence.first) tokens[from - 1].text else ""
        values["next"] = if (to <= sentence.last) tokens[to].text else ""
        values["original_gloss"] = rules.glosses[WritingToken.normalize(original.trim())] ?: ""
        values["replacement_gloss"] = rules.glosses[WritingToken.normalize(edit.replacement.trim())] ?: ""
        var template = template(rule, kind)
        if (rule.message == null && kind.id == "confused_words" && values["original_gloss"]!!.isNotEmpty() &&
            values["replacement_gloss"]!!.isNotEmpty()
        ) {
            template = rules.messages.getValue("confused_words.gloss")
        }
        if (rule.message == null && expanded.isEmpty()) rules.messages["${kind.id}.remove"]?.let { template = it }
        val suggestion = WritingSuggestion(
            start = edit.start, end = edit.end, original = original, replacement = edit.replacement,
            markStart = edit.markStart, markEnd = edit.markEnd,
            kind = kind.id, category = kind.category, title = kind.title,
            message = WritingEdits.format(template, values),
            mechanical = kind.mechanical, source = WritingSuggestion.Source.RULE, rule = rule.id,
        )
        return Found(suggestion, from, to)
    }

    private fun template(rule: WritingRule, kind: WritingRules.Kind): String =
        rule.message?.let { rules.messages[it] ?: it } ?: kind.message

    // ── information only ───────────────────────────────────────────────────

    private fun longSentences(text: String, tokens: List<WritingToken>, sentences: List<WritingSentence>): List<WritingSuggestion> {
        val kind = rules.kind("long_sentence")
        return sentences.mapNotNull { s ->
            val words = (s.first..s.last).count { tokens[it].hasLetter }
            if (words <= rules.longSentenceWords) return@mapNotNull null
            WritingSuggestion(
                start = s.start, end = s.end, original = text.substring(s.start, s.end), replacement = null,
                markStart = s.start, markEnd = s.end, kind = kind.id, category = kind.category, title = kind.title,
                message = WritingEdits.format(kind.message, mapOf("count" to "$words")),
                mechanical = false, source = WritingSuggestion.Source.TEXT,
            )
        }
    }

    /** A word used [WritingRules.overusedWordCount] times in a paragraph, marked where that happens; never one in [keep]. */
    private fun overusedWords(tokens: List<WritingToken>, sentences: List<WritingSentence>, keep: Set<String>): List<WritingSuggestion> {
        val kind = rules.kind("overused_word")
        val out = ArrayList<WritingSuggestion>()
        sentences.groupBy { it.paragraph }.values.forEach { paragraph ->
            val counts = HashMap<String, Int>()
            for (s in paragraph) {
                for (i in s.first..s.last) {
                    val t = tokens[i]
                    if (!t.hasLetter || t.key.length < 4 || t.key in rules.stopwords || t.key in keep) continue
                    val n = (counts[t.key] ?: 0) + 1
                    counts[t.key] = n
                    if (n == rules.overusedWordCount) {
                        out.add(
                            WritingSuggestion(
                                start = t.start, end = t.end, original = t.text, replacement = null,
                                markStart = t.start, markEnd = t.end, kind = kind.id, category = kind.category,
                                title = kind.title,
                                message = WritingEdits.format(kind.message, mapOf("word" to t.key, "count" to "$n")),
                                mechanical = false, source = WritingSuggestion.Source.TEXT,
                            ),
                        )
                    }
                }
            }
        }
        return out
    }

    // ── filters and merging ────────────────────────────────────────────────

    private fun offeredOnTypedText(
        s: WritingSuggestion,
        text: String,
        lowercaseStyle: Boolean,
        sentenceStarts: Set<Int>,
    ): Boolean {
        if (s.source != WritingSuggestion.Source.MODEL) return true
        val added = s.shownReplacement ?: return true
        // A full stop, question or exclamation mark added where a paragraph stops.
        if (s.shownOriginal.isEmpty() && added.isNotEmpty() && added.all { it in ".!?" }) {
            val after = text.substring(s.end)
            if (after.isBlank() || after.trimStart(' ', '\t').startsWith("\n")) return false
        }
        if (s.kind == "capitalization" && WritingToken.normalize(s.shownOriginal).let { it != "i" && !it.startsWith("i'") }) {
            // Only a sentence start, and not in text typed in lower case on purpose.
            return !lowercaseStyle && s.markStart in sentenceStarts
        }
        return true
    }

    /**
     * Actionable suggestions never conflict: correctness first, rules before
     * the model. Correctness is listed before the style groups, so a card
     * about clarity or tone never comes ahead of a mistake.
     */
    private fun merge(found: List<WritingSuggestion>, text: String): List<WritingSuggestion> {
        fun priority(s: WritingSuggestion) = s.category.ordinal * 2 + if (s.source == WritingSuggestion.Source.RULE) 0 else 1
        val accepted = ArrayList<WritingSuggestion>()
        for (s in found.filter { it.isActionable }.sortedWith(compareBy({ priority(it) }, { it.start }))) {
            if (accepted.none { conflicts(it, s, text) }) accepted.add(s)
        }
        val info = found.filter { !it.isActionable }.distinctBy { Triple(it.kind, it.start, it.end) }
        return (accepted + info).sortedWith(compareBy({ it.category.ordinal }, { it.markStart }, { priority(it) }))
    }

    /**
     * Two suggestions that overlap, or one that adds words right beside the
     * other: "thanks for invite me" can gain "the" or become "thanks for
     * inviting me", and accepting both reads "for the inviting me".
     */
    private fun conflicts(a: WritingSuggestion, b: WritingSuggestion, text: String): Boolean =
        a.overlaps(b) || addsBeside(a, b, text) || addsBeside(b, a, text)

    private fun addsBeside(add: WritingSuggestion, other: WritingSuggestion, text: String): Boolean {
        if (add.shownOriginal.isNotEmpty() || add.shownReplacement?.any(Char::isLetter) != true) return false
        val from = if (add.start <= other.start) add.end else other.end
        val to = if (add.start <= other.start) other.start else add.start
        return from <= to && text.substring(from, to).isBlank()
    }

    // ── tone and statistics ───────────────────────────────────────────────

    private fun tones(text: String, tokens: List<WritingToken>): List<Tone> {
        if (text.length < rules.toneMinimumCharacters) return emptyList()
        val words = tokens.filter { it.hasLetter }
        val keys = words.map { it.key }
        val joined = " " + keys.joinToString(" ") + " "
        val exclamations = tokens.count { it.text == "!" }.coerceAtMost(2)
        val questions = tokens.count { it.text == "?" }.coerceAtMost(2)
        val smileys = text.codePoints().filter { it in SMILEYS }.count().toInt().coerceAtMost(2)
        val shouting = words.count { w -> w.text.length >= 3 && w.text.all { it.isUpperCase() } }.coerceAtMost(2)
        val scored = rules.tones.map { tone ->
            var score = keys.count { it in tone.words } * 2
            score += tone.phrases.sumOf { phrase -> occurrences(joined, " ${WritingToken.normalize(phrase)} ") * 4 }
            score += when (tone.id) {
                "excited" -> exclamations * 2
                "friendly" -> exclamations + smileys * 2
                "curious" -> questions * 2
                "urgent" -> shouting * 2
                else -> 0
            }
            Tone(tone.id, tone.label, tone.emoji, score)
        }
        return scored.filter { it.score >= rules.toneMinimumScore }.sortedByDescending { it.score }.take(3)
    }

    private fun occurrences(haystack: String, needle: String): Int {
        var count = 0
        var at = haystack.indexOf(needle)
        while (at >= 0) {
            count++
            at = haystack.indexOf(needle, at + needle.length - 1)
        }
        return count
    }

    private fun stats(text: String, tokens: List<WritingToken>, sentences: List<WritingSentence>, found: List<WritingSuggestion>): Stats {
        val words = tokens.filter { it.hasLetter }
        val sentenceCount = sentences.count { s -> (s.first..s.last).any { tokens[it].hasLetter } }
        val syllables = words.sumOf { syllables(it.key) }
        val readability = if (words.isEmpty() || sentenceCount == 0) {
            null
        } else {
            (206.835 - 1.015 * (words.size.toDouble() / sentenceCount) - 84.6 * (syllables.toDouble() / words.size))
                .roundToInt().coerceIn(0, 100)
        }
        val score = if (words.isEmpty()) {
            null
        } else {
            val weight = found.sumOf { rules.scoreWeights[it.category] ?: 1.0 }
            (100.0 - weight * 100.0 / maxOf(words.size, rules.scoreMinimumWords)).roundToInt().coerceIn(0, 100)
        }
        return Stats(
            words = words.size,
            characters = text.codePointCount(0, text.length),
            sentences = sentenceCount,
            readingSeconds = ceil(words.size * 60.0 / rules.readingWordsPerMinute).toInt(),
            speakingSeconds = ceil(words.size * 60.0 / rules.speakingWordsPerMinute).toInt(),
            readability = readability,
            readabilityLabel = readability?.let(::readabilityLabel),
            score = score,
        )
    }

    companion object {
        private val SMILEYS = setOf(0x1F60A, 0x1F642, 0x1F604, 0x1F600, 0x1F603, 0x1F601, 0x2764, 0x1F44D, 0x1F389, 0x1F60D, 0x1F970)

        /** Vowel groups, less a silent final "e": "make" 1, "table" 2, "readability" 5. */
        fun syllables(word: String): Int {
            var groups = 0
            var inGroup = false
            for (c in word) {
                val vowel = c in "aeiouy"
                if (vowel && !inGroup) groups++
                inGroup = vowel
            }
            if (groups > 1 && word.endsWith("e") && !word.endsWith("le") && !word.endsWith("ee")) groups--
            return maxOf(groups, 1)
        }

        fun readabilityLabel(score: Int): String = when {
            score >= 90 -> "Very easy to read"
            score >= 80 -> "Easy to read"
            score >= 70 -> "Fairly easy to read"
            score >= 60 -> "Plain English"
            score >= 50 -> "Fairly hard to read"
            score >= 30 -> "Hard to read"
            else -> "Very hard to read"
        }

        private fun wordsIn(text: String): Set<String> = WritingText.tokenize(text).filter { it.isWord }.mapTo(HashSet()) { it.key }

        /**
         * [suggestions] found for [old], carried over to [new]: those wholly
         * before or after the one changed region shift with it; any the edit
         * touched are dropped, as is one whose word the edit runs into.
         */
        fun rebase(suggestions: List<WritingSuggestion>, old: String, new: String): List<WritingSuggestion> {
            if (old == new) return suggestions
            var prefix = 0
            val shorter = minOf(old.length, new.length)
            while (prefix < shorter && old[prefix] == new[prefix]) prefix++
            var suffix = 0
            while (suffix < shorter - prefix && old[old.length - 1 - suffix] == new[new.length - 1 - suffix]) suffix++
            val oldEnd = old.length - suffix
            val delta = new.length - old.length
            return suggestions.mapNotNull { s ->
                val before = s.end < prefix || (s.end == prefix && s.start < s.end && !wordChar(new, prefix))
                val after = s.start > oldEnd || (s.start == oldEnd && s.start < s.end && !wordChar(new, oldEnd + delta - 1))
                when {
                    before -> s
                    after -> s.copy(start = s.start + delta, end = s.end + delta, markStart = s.markStart + delta, markEnd = s.markEnd + delta)
                    else -> null
                }
            }
        }

        private fun wordChar(text: String, index: Int): Boolean = index in text.indices && text[index].isLetterOrDigit()

        /** [text] with [suggestion] applied, or null when that span no longer says what was checked. */
        fun apply(text: String, suggestion: WritingSuggestion): String? {
            val replacement = suggestion.replacement ?: return null
            if (suggestion.end > text.length || text.substring(suggestion.start, suggestion.end) != suggestion.original) return null
            return text.substring(0, suggestion.start) + replacement + text.substring(suggestion.end)
        }
    }
}
