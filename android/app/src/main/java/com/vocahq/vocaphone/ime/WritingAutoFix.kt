package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.writing.WritingCheck
import com.vocahq.vocaphone.writing.WritingSuggestion

/** What "Fix obvious typos as I type" may change without a tap. */
internal val AUTO_FIX_KINDS = setOf("spelling", "apostrophe")

/**
 * [suggestions], from a report that checked [checked], as edits to [fresh]:
 * each moved to where its words now are, in editor positions, and kept only
 * if they still say what was checked.
 */
internal fun writingFixesFor(
    suggestions: List<WritingSuggestion>,
    checked: String,
    fresh: WritingCheckSession.Field,
): List<WritingFix> = suggestions.mapNotNull { suggestion ->
    val replacement = suggestion.replacement ?: return@mapNotNull null
    val moved = WritingCheck.rebase(listOf(suggestion), checked, fresh.text).singleOrNull() ?: return@mapNotNull null
    if (!fresh.text.regionMatches(moved.start, moved.original, 0, moved.original.length)) return@mapNotNull null
    WritingFix(fresh.offset + moved.start, fresh.offset + moved.end, replacement, suggestion)
}

/**
 * The typo in [report] that "Fix obvious typos as I type" would correct: the
 * last finished one before the cursor the check saw. None while an earlier
 * automatic fix still offers Undo ([undoPending]): one fix per Undo, so Undo
 * always puts back the word it names.
 */
internal fun autoFixCandidate(report: WritingCheckSession.Report, undoPending: Boolean): WritingSuggestion? {
    if (undoPending) return null
    return report.suggestions.filter {
        it.source == WritingSuggestion.Source.RULE && it.kind in AUTO_FIX_KINDS && it.isActionable &&
            it.end < report.field.cursor
    }.maxByOrNull { it.start }
}

/**
 * [candidate] as an edit to [fresh], the field read just before the edit, or
 * null when the report is stale there. The cursor may have moved, or the
 * text changed, after the check read the field and before the keyboard's
 * own refresh dropped its report: the fix is made only if the text from the
 * typo to the cursor is still what the check saw, so it still ends before
 * the cursor and its Undo can be offered.
 */
internal fun autoFixFor(
    report: WritingCheckSession.Report,
    candidate: WritingSuggestion,
    fresh: WritingCheckSession.Field,
): WritingFix? {
    val fix = writingFixesFor(listOf(candidate), report.field.text, fresh).singleOrNull() ?: return null
    val end = fix.end - fresh.offset
    if (end >= fresh.cursor) return null
    val gap = report.field.text.substring(candidate.end, report.field.cursor)
    if (end + gap.length != fresh.cursor || !fresh.text.regionMatches(end, gap, 0, gap.length)) return null
    return fix
}

/**
 * One automatic fix: [typed] at editor [position] became [wrote]. [tail]
 * is the text from [position] to where the fix left the cursor, so Undo
 * restores this occurrence and no other, and only while the field there
 * still reads as the fix left it. [key] is dismissed on Undo; the
 * suggestion itself has already left the report.
 */
internal data class AutoFix(
    val label: String,
    val position: Int,
    val wrote: String,
    val typed: String,
    val key: String,
    val tail: String,
) {
    /**
     * Still offered while [before], the text before the cursor, ends with
     * what the fix left: an edit or a cursor move ends the offer.
     */
    fun stillOffered(before: String, hasSelection: Boolean): Boolean {
        if (hasSelection) return false
        return if (tail.length <= before.length) before.endsWith(tail) else tail.endsWith(before)
    }

    /**
     * The edit that puts back what was typed, when [field] still reads as the
     * fix left it with the cursor where the fix put it; null otherwise.
     */
    fun undoIn(field: WritingCheckSession.Field): WritingFix? {
        val at = position - field.offset
        if (at < 0 || field.offset + field.cursor != position + tail.length) return null
        if (!field.text.regionMatches(at, tail, 0, tail.length)) return null
        return WritingFix(position, position + wrote.length, typed)
    }

    companion object {
        /** The Undo for [fix], which the editor took, in [fresh] as read just before the edit. */
        fun of(fix: WritingFix, fresh: WritingCheckSession.Field): AutoFix? {
            val suggestion = fix.suggestion ?: return null
            val start = fix.start - fresh.offset
            val end = fix.end - fresh.offset
            if (start < 0 || end > fresh.cursor) return null
            return AutoFix(
                label = suggestion.label,
                position = fix.start,
                wrote = fix.replacement,
                typed = fresh.text.substring(start, end),
                key = suggestion.key,
                tail = fix.replacement + fresh.text.substring(end, fresh.cursor),
            )
        }
    }
}
