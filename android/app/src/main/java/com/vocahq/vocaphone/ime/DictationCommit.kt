package com.vocahq.vocaphone.ime

import android.view.inputmethod.InputConnection
import com.vocahq.vocaphone.core.TextInsertion

/**
 * One bounded context read at each boundary per finished dictation, never per key.
 *
 * [composingActive] is whether the keyboard still owns a composing region in
 * the editor. `commitText` replaces that region, so a half-typed "hel" left
 * there when the mic was tapped would be overwritten by the transcript. It is
 * finished first, inside the same batch, so the editor reports one selection
 * change for the whole edit. When it is false the IPC is skipped.
 *
 * [selectionStart] and [selectionEnd] are the editor's last reported selection
 * (from onUpdateSelection, so no extra read). Several editors collapse a
 * highlight when composing is finished, which would drop the transcript at the
 * caret instead of replacing the selected text; a range selection is put back
 * before the commit, as cycleSelectionCase does.
 */
internal fun commitDictation(
    connection: InputConnection,
    transcript: String,
    composingActive: Boolean,
    selectionStart: Int = -1,
    selectionEnd: Int = -1,
): Boolean = commitDictationText(connection, transcript, composingActive, selectionStart, selectionEnd) != null

/**
 * [commitDictation], returning the text as committed — the transcript with
 * the spacing added around it — or null when the editor refused it.
 */
internal fun commitDictationText(
    connection: InputConnection,
    transcript: String,
    composingActive: Boolean,
    selectionStart: Int = -1,
    selectionEnd: Int = -1,
    collapseTo: Int = -1,
): String? {
    if (transcript.isBlank()) return null
    runCatching { connection.beginBatchEdit() }
    try {
        if (composingActive) {
            runCatching { connection.finishComposingText() }
            if (selectionStart >= 0 && selectionEnd >= 0 && selectionStart != selectionEnd) {
                runCatching { connection.setSelection(selectionStart, selectionEnd) }
            }
        }
        // A selection that is not the one the dictation was started over is
        // left alone: the transcript goes in at its end instead of over it.
        if (collapseTo >= 0) runCatching { connection.setSelection(collapseTo, collapseTo) }
        // These APIs return context outside the selection being replaced. Missing
        // context is allowed; editors that omit it should still accept dictation.
        val before = runCatching { connection.getTextBeforeCursor(1, 0)?.toString() }.getOrNull().orEmpty()
        val after = runCatching { connection.getTextAfterCursor(1, 0)?.toString() }.getOrNull().orEmpty()
        val prepared = TextInsertion.preparedTranscript(transcript, before, after)
        return prepared.takeIf { runCatching { connection.commitText(prepared, 1) }.getOrDefault(false) }
    } finally {
        runCatching { connection.endBatchEdit() }
    }
}

/**
 * Dictating over a selection: the transcript replaces it only if the editor
 * still has that same selection when the transcript arrives.
 */
internal object DictationSelection {
    data class Range(val start: Int, val end: Int, val text: String) {
        val isEmpty: Boolean get() = start == end
    }

    sealed interface Target {
        /** Commit as the editor stands: over the selection it still has, or at a plain cursor. */
        data object AsIs : Target

        /** Put the cursor at [position] first, leaving the selected text alone. */
        data class CollapseTo(val position: Int) : Target
    }

    /** The selection to remember when dictation starts, or null for a plain cursor. */
    fun remember(start: Int, end: Int, text: String?): Range? {
        if (start < 0 || end < 0 || start == end || text.isNullOrEmpty()) return null
        return Range(minOf(start, end), maxOf(start, end), text)
    }

    /**
     * Where the transcript goes, given the selection [remembered] at the start
     * and the one the editor has now ([current], read once at insert time).
     */
    fun target(remembered: Range?, current: Range?): Target = when {
        current == null || current.isEmpty -> Target.AsIs
        remembered != null && remembered == current -> Target.AsIs
        else -> Target.CollapseTo(current.end)
    }

    /**
     * As [target], from the editor's reported selection [start]..[end] and
     * its text as read ([text], null when the editor would not say). A
     * selection whose text cannot be read is never replaced: it might be one
     * the user made after the dictation started, so the transcript goes in at
     * its end instead.
     */
    fun target(remembered: Range?, start: Int, end: Int, text: String?): Target {
        if (start < 0 || end < 0 || start == end) return Target.AsIs
        val current = remember(start, end, text) ?: return Target.CollapseTo(maxOf(start, end))
        return target(remembered, current)
    }
}
