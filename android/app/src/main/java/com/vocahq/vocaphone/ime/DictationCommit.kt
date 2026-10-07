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
): Boolean {
    if (transcript.isBlank()) return false
    runCatching { connection.beginBatchEdit() }
    try {
        if (composingActive) {
            runCatching { connection.finishComposingText() }
            if (selectionStart >= 0 && selectionEnd >= 0 && selectionStart != selectionEnd) {
                runCatching { connection.setSelection(selectionStart, selectionEnd) }
            }
        }
        // These APIs return context outside the selection being replaced. Missing
        // context is allowed; editors that omit it should still accept dictation.
        val before = runCatching { connection.getTextBeforeCursor(1, 0)?.toString() }.getOrNull().orEmpty()
        val after = runCatching { connection.getTextAfterCursor(1, 0)?.toString() }.getOrNull().orEmpty()
        val prepared = TextInsertion.preparedTranscript(transcript, before, after)
        return runCatching { connection.commitText(prepared, 1) }.getOrDefault(false)
    } finally {
        runCatching { connection.endBatchEdit() }
    }
}
