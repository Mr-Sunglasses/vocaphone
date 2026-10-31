package com.vocahq.vocaphone.grammar

/**
 * "Check grammar while typing": which typed text goes to the grammar model,
 * and how its answer becomes one edit at the cursor.
 *
 * Pure, so every decision here is unit-tested without a keyboard or a model.
 * The keyboard reads the text before the cursor after the user pauses, asks
 * [region] what to check, runs [GrammarCorrector] over it off the main thread,
 * turns the answer into a [Fix] the strip can show, and on a tap asks [edit]
 * for the deletion and insertion that apply it — against the text as it is
 * then, not as it was when the check started. Nothing is ever changed without
 * that tap. Mirrors `ios/VocaPhoneShared/TypedGrammar.swift`.
 */
object TypedGrammar {
    /** How much text before the cursor one check reads. */
    const val READ_LIMIT = 600

    /** The most text one check sends to the model: two ordinary sentences. */
    const val MAX_REGION = 400

    /** Fewer words than this give the model nothing to read a sentence from. */
    const val MIN_WORDS = 2

    /**
     * A correction the strip can offer: [checked] is the typed text the model
     * read, [corrected] what it suggests, and the two agree up to [start].
     * [original] and [replacement] are the changed words alone, for the chip.
     */
    data class Fix(
        val checked: String,
        val corrected: String,
        val start: Int,
        val original: String,
        val replacement: String,
    ) {
        /** What the chip says: the words as typed, and what they become. */
        val label: String
            get() = when {
                replacement.isEmpty() -> "Remove “$original”"
                original.isEmpty() -> "Add “$replacement”"
                else -> "$original → $replacement"
            }
    }

    /** Delete [deleteBefore] characters before the cursor, then type [insert]. */
    data class Edit(val deleteBefore: Int, val insert: String)

    /**
     * The text to check, given the text before the cursor, or null when there
     * is nothing to check yet.
     *
     * Only at a word boundary: a check mid-word would read "kno" as a word to
     * correct. Only the cursor's own paragraph, and only its last two
     * sentences, finished or not: the sentence just ended is the one a person
     * looks back at, and the model reads a sentence at a time anyway. [startKnown]
     * says whether [before] begins at the start of the field; when it does not,
     * its first sentence is probably cut off, and is left out unless it reads
     * like a sentence start.
     */
    fun region(before: String, startKnown: Boolean): String? {
        val last = before.lastOrNull() ?: return null
        if (last.isLetterOrDigit() || last in WORD_JOINERS) return null
        val body = before.trimEnd()
        if (body.isEmpty()) return null
        val paragraphStart = body.indexOfLast { it == '\n' || it == '\r' } + 1
        val paragraph = body.substring(paragraphStart)
        val known = startKnown || paragraphStart > 0
        val starts = buildList {
            if (known || paragraph.firstOrNull()?.isUpperCase() == true) add(0)
            SENTENCE_BOUNDARY.findAll(paragraph).forEach { add(it.range.last + 1) }
        }.filter { it < paragraph.length }
        if (starts.isEmpty()) return null
        // The last two sentences if they fit, the last one alone if not.
        val start = starts.takeLast(2).firstOrNull { paragraph.length - it <= MAX_REGION } ?: return null
        val region = paragraph.substring(start)
        if (LATIN_WORD.findAll(region).count() < MIN_WORDS) return null
        return region
    }

    /**
     * The fix the model's [corrected] text offers for [checked], or null when
     * there is nothing worth a chip.
     *
     * Two things the model does are taken back first, because on typed text
     * they are not corrections: a full stop added to a sentence still being
     * written, and a capital put on a first word the user typed lower case on
     * purpose, which is how people write in chat. Past that, a change of case
     * alone is offered only when it is the pronoun "I".
     */
    fun fix(checked: String, corrected: String): Fix? {
        var out = corrected
        val typedRun = checked.takeLastWhile { it in TRAILING_PUNCTUATION }
        val outRun = out.takeLastWhile { it in TRAILING_PUNCTUATION }
        if (outRun.length > typedRun.length && outRun.startsWith(typedRun)) {
            out = out.dropLast(outRun.length - typedRun.length).trimEnd()
        }
        val first = checked.firstOrNull()
        if (first != null && first.isLowerCase() && !isPronounI(checked.takeWhile { !it.isWhitespace() }) &&
            out.firstOrNull() == first.uppercaseChar()
        ) {
            out = first + out.substring(1)
        }
        if (out == checked || out.isBlank()) return null
        val typed = words(checked)
        val offered = words(out)
        if (out.equals(checked, ignoreCase = true) &&
            typed.zip(offered).none { (a, b) -> isPronounI(checked.substring(a)) && checked.substring(a) != out.substring(b) }
        ) {
            return null
        }
        // Whole words, matched from both ends, so the chip says "don't →
        // doesn't" rather than "n't → esn't". A word only counts as unchanged
        // where it also sits at the same place, which is what lets the edit
        // keep everything before the first change.
        val shorter = minOf(typed.size, offered.size)
        var prefix = 0
        while (prefix < shorter && typed[prefix] == offered[prefix] &&
            checked.substring(typed[prefix]) == out.substring(offered[prefix])
        ) {
            prefix++
        }
        var suffix = 0
        while (suffix < shorter - prefix) {
            val a = typed[typed.size - 1 - suffix]
            val b = offered[offered.size - 1 - suffix]
            if (checked.length - a.first != out.length - b.first ||
                checked.substring(a) != out.substring(b)
            ) {
                break
            }
            suffix++
        }
        val start = if (prefix == 0) 0 else typed[prefix - 1].last + 1
        val end = if (suffix == 0) checked.length else typed[typed.size - suffix].first
        val tail = checked.length - end
        return Fix(
            checked = checked,
            corrected = out,
            start = start,
            original = checked.substring(start, end).trim(),
            replacement = out.substring(start, out.length - tail).trim(),
        )
    }

    private fun words(text: String): List<IntRange> = NON_SPACE.findAll(text).map { it.range }.toList()

    private fun isPronounI(word: String) = word == "i" || word == "I" ||
        word.startsWith("i'") || word.startsWith("i’") || word.startsWith("I'") || word.startsWith("I’")

    /**
     * How to apply [fix] to the text before the cursor as it is now, or null
     * when that text no longer ends with what was checked — the user typed on,
     * moved the cursor or edited the sentence — so the fix no longer describes
     * it. Whitespace typed after the check is kept.
     */
    fun edit(fix: Fix, before: String): Edit? {
        val body = before.trimEnd()
        if (!body.endsWith(fix.checked)) return null
        val trailing = before.substring(body.length)
        return Edit(
            deleteBefore = fix.checked.length - fix.start + trailing.length,
            insert = fix.corrected.substring(fix.start) + trailing,
        )
    }

    /**
     * Whether a fix found for an earlier read still describes the text before
     * the cursor, judged from the keyboard's short window of it: the window
     * and the checked text have to end the same way.
     */
    fun stillDescribes(fix: Fix, window: String): Boolean {
        val body = window.trimEnd()
        if (body.isEmpty()) return false
        return body.endsWith(fix.checked) || fix.checked.endsWith(body)
    }

    private val WORD_JOINERS = setOf('\'', '’', '-')
    private val TRAILING_PUNCTUATION = setOf('.', ',', '!', '?', ';', ':')
    private val LATIN_WORD = Regex("[A-Za-z]+(?:['’][A-Za-z]+)*")
    private val NON_SPACE = Regex("\\S+")
    /** A sentence end and the space after it, closing quotes and brackets included. */
    private val SENTENCE_BOUNDARY = Regex("[.!?][\"'”’)\\]]*\\s+")
}
