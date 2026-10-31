package com.vocahq.vocaphone.writing

/**
 * One Writing check suggestion, Grammarly's card in data: what to change,
 * into what, which of the four groups it belongs to, and why.
 *
 * [start] and [end] are the UTF-16 range [replacement] replaces, whitespace
 * included where a word is added or removed; [markStart] and [markEnd] are
 * the word to underline. A null [replacement] is information only (passive
 * voice, a long sentence): there is nothing to apply.
 */
data class WritingSuggestion(
    val start: Int,
    val end: Int,
    val original: String,
    val replacement: String?,
    val markStart: Int,
    val markEnd: Int,
    val kind: String,
    val category: WritingCategory,
    val title: String,
    val message: String,
    /** Spelling, punctuation and the like: safe to accept all at once. */
    val mechanical: Boolean,
    val source: Source,
    /** The rule's id for [Source.RULE]. */
    val rule: String? = null,
) {
    enum class Source { MODEL, RULE, TEXT }

    /** The words as typed; for a removal, only the words removed, not a comma or space taken along. */
    val shownOriginal: String
        get() = if (replacement?.isBlank() == true && start <= markStart && markStart < markEnd && markEnd <= end) {
            original.substring(markStart - start, markEnd - start).trim()
        } else {
            original.trim()
        }
    val shownReplacement: String? get() = replacement?.trim()

    /** What a chip says: the words as typed and what they become. */
    val label: String
        get() {
            val replacement = shownReplacement ?: return title
            return when {
                replacement.isEmpty() -> "Remove “$shownOriginal”"
                shownOriginal.isEmpty() -> "Add “$replacement”"
                else -> "$shownOriginal → $replacement"
            }
        }

    /** The same change anywhere in a field; what dismissing one remembers. */
    val key: String get() = "$kind|${WritingToken.normalize(shownOriginal)}|${shownReplacement?.let(WritingToken::normalize)}"

    val isActionable: Boolean get() = replacement != null

    fun overlaps(other: WritingSuggestion): Boolean {
        if (start < other.end && other.start < end) return true
        if (start == end && other.start <= start && start <= other.end) return true
        if (other.start == other.end && start <= other.start && other.start <= end) return true
        return false
    }
}

/**
 * Turns "these tokens become this text" into a [WritingSuggestion]'s ranges,
 * the same way for the rules and for the model's edits.
 */
internal object WritingEdits {
    /**
     * Removed tokens `[from, to)` of [tokens] become [inserted] (already
     * spaced, nothing around it). [floor] is the first token the edit may
     * reach back to for its whitespace: the sentence's first token.
     *
     * The spaces come from both neighbours, so accepting the edit never runs
     * two words together or leaves a space inside a bracket: "I go(store)"
     * gains "the " after "(", and removing the comma in "Hello ,world" keeps a
     * space. A phrase removed between commas takes one of them along: "It was,
     * needless to say, a great day." becomes "It was a great day."
     */
    fun build(
        text: String,
        tokens: List<WritingToken>,
        floor: Int,
        from: Int,
        to: Int,
        inserted: String,
    ): Edit {
        val removed = to > from
        return when {
            removed && inserted.isNotEmpty() -> replace(tokens, floor, from, to, inserted)
            removed -> remove(tokens, floor, from, to)
            from > floor -> {
                val anchor = tokens[from - 1]
                val words = WritingText.tokenize(inserted)
                val left = if (spaced(anchor.text, words.firstOrNull()?.text ?: inserted)) " " else ""
                val next = tokens.getOrNull(from)
                val right = if (next != null && next.start == anchor.end && spaced(words.lastOrNull()?.text ?: inserted, next.text)) " " else ""
                Edit(anchor.end, anchor.end, left + inserted + right, anchor.start, anchor.end)
            }
            else -> {
                val next = tokens[from]
                val right = if (spaced(WritingText.tokenize(inserted).lastOrNull()?.text ?: inserted, next.text)) " " else ""
                Edit(next.start, next.start, inserted + right, next.start, next.end)
            }
        }.also { check(it.start <= it.end && it.end <= text.length) }
    }

    /** Tokens swapped for others: a space only where two words would otherwise touch. */
    private fun replace(tokens: List<WritingToken>, floor: Int, from: Int, to: Int, inserted: String): Edit {
        val words = WritingText.tokenize(inserted)
        val first = tokens[from]
        val last = tokens[to - 1]
        val before = tokens.getOrNull(from - 1)?.takeIf { from > floor }
        val after = tokens.getOrNull(to)
        val left = if (before != null && before.end == first.start && before.isWord && words.firstOrNull()?.isWord == true) " " else ""
        val right = if (after != null && after.start == last.end && after.isWord && words.lastOrNull()?.isWord == true) " " else ""
        return Edit(first.start, last.end, left + inserted + right, first.start, last.end)
    }

    private fun remove(tokens: List<WritingToken>, floor: Int, removeFrom: Int, removeTo: Int): Edit {
        val markStart = tokens[removeFrom].start
        val markEnd = tokens[removeTo - 1].end
        var from = removeFrom
        var to = removeTo
        val left = tokens.getOrNull(from - 1)?.takeIf { from > floor }
        val right = tokens.getOrNull(to)
        if (left?.text == ",") {
            when {
                // ", needless to say," between words: both commas go.
                right?.text == "," && from - 1 > floor -> {
                    from--
                    to++
                }
                // ", if that makes sense." at the end: the comma goes.
                right == null || right.text in CLOSING -> from--
            }
        } else if (left == null && right?.text == ",") {
            to++
        }
        val l = tokens.getOrNull(from - 1)?.takeIf { from > floor }
        val r = tokens.getOrNull(to)
        val first = tokens[from]
        val last = tokens[to - 1]
        return when {
            l == null && r == null -> Edit(first.start, last.end, "", markStart, markEnd)
            // At the start, take the space after it.
            l == null -> Edit(first.start, r!!.start, "", markStart, markEnd)
            // At the end, take the space before it.
            r == null -> Edit(l.end, last.end, "", markStart, markEnd)
            else -> {
                val wanted = spaced(l.text, r.text)
                val gapBefore = first.start > l.end
                val gapAfter = r.start > last.end
                when {
                    // Usually the space before goes and the one after stays.
                    gapAfter == wanted -> Edit(l.end, last.end, "", markStart, markEnd)
                    gapBefore == wanted -> Edit(first.start, r.start, "", markStart, markEnd)
                    else -> Edit(l.end, r.start, if (wanted) " " else "", markStart, markEnd)
                }
            }
        }
    }

    /** Whether a space belongs between [left] and [right]: not after "(" or a hyphen, not before "," or ")". */
    private fun spaced(left: String, right: String): Boolean =
        left !in OPENING && left !in JOINING && right !in JOINING && right !in ATTACHED

    private val CLOSING = setOf(".", "!", "?", ";", ":", "…")
    private val ATTACHED = setOf(",", ".", ";", ":", "!", "?", "…", ")", "]", "}", "”", "’", "»")
    private val OPENING = setOf("(", "[", "{", "“", "‘", "«")
    private val JOINING = setOf("-", "‐", "‑", "/")

    data class Edit(val start: Int, val end: Int, val replacement: String, val markStart: Int, val markEnd: Int) {
        /** What a card shows as replaced, as [WritingSuggestion.shownOriginal]. */
        fun shownOriginal(text: String): String =
            (if (replacement.isBlank()) text.substring(markStart, markEnd) else text.substring(start, end)).trim()
    }

    /** Fills `{name}` placeholders from [values]; unknown names become empty. */
    fun format(template: String, values: Map<String, String>): String =
        PLACEHOLDER.replace(template) { values[it.groupValues[1]] ?: "" }

    private val PLACEHOLDER = Regex("\\{(\\w+)\\}")
}
