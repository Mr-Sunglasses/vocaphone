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
 */
internal fun commitDictation(
    connection: InputConnection,
    transcript: String,
    composingActive: Boolean,
): Boolean {
    if (transcript.isBlank()) return false
    runCatching { connection.beginBatchEdit() }
    try {
        if (composingActive) runCatching { connection.finishComposingText() }
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
