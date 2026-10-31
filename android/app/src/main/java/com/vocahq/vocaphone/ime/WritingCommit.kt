package com.vocahq.vocaphone.ime

import android.view.inputmethod.InputConnection
import com.vocahq.vocaphone.writing.WritingSuggestion

/**
 * One Writing check edit in editor positions: `[start, end)` becomes
 * [replacement]. [suggestion] is the report's own suggestion it came from, in
 * the report's offsets; null for an Undo.
 */
internal data class WritingFix(
    val start: Int,
    val end: Int,
    val replacement: String,
    val suggestion: WritingSuggestion? = null,
)

/** What [commitWritingFixes] changed: the fixes that landed, last first, and where the cursor was put. */
internal data class WritingCommit(val applied: List<WritingFix>, val cursor: Int)

/**
 * Applies [fixes] as one batch edit, from the end of the field back so each
 * edit leaves the earlier offsets alone, then puts the cursor back where the
 * user left it ([cursor], moved by the edits before it).
 *
 * An editor that refuses the selection would take `commitText` at the cursor
 * instead of over the flagged words, so a refused selection or commit stops
 * there: only the fixes in [WritingCommit.applied] reached the editor, and
 * only those may be taken off the report. A fix overlapping one already made
 * is skipped. The batch is always closed.
 */
internal fun commitWritingFixes(
    connection: InputConnection,
    fixes: List<WritingFix>,
    cursor: Int,
    composingActive: Boolean,
): WritingCommit {
    val applied = ArrayList<WritingFix>()
    var at = cursor
    var floor = Int.MAX_VALUE
    runCatching { connection.beginBatchEdit() }
    try {
        if (composingActive) runCatching { connection.finishComposingText() }
        for (fix in fixes.sortedByDescending { it.start }) {
            if (fix.end > floor) continue
            if (!runCatching { connection.setSelection(fix.start, fix.end) }.getOrDefault(false)) break
            if (!runCatching { connection.commitText(fix.replacement, 1) }.getOrDefault(false)) break
            applied += fix
            floor = fix.start
            at = when {
                at >= fix.end -> at + fix.replacement.length - (fix.end - fix.start)
                at > fix.start -> fix.start + fix.replacement.length
                else -> at
            }
        }
        // Also collapses a selection made for a commit that was then refused.
        runCatching { connection.setSelection(at, at) }
    } finally {
        runCatching { connection.endBatchEdit() }
    }
    return WritingCommit(applied, at)
}
