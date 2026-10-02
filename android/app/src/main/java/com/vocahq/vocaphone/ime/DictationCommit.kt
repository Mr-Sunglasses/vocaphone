package com.vocahq.vocaphone.ime

import android.view.inputmethod.InputConnection
import com.vocahq.vocaphone.core.TextInsertion

/** One bounded context read at each boundary per finished dictation, never per key. */
internal fun commitDictation(connection: InputConnection, transcript: String): Boolean {
    if (transcript.isBlank()) return false
    // These APIs return context outside the selection being replaced. Missing
    // context is allowed; editors that omit it should still accept dictation.
    val before = runCatching { connection.getTextBeforeCursor(1, 0)?.toString() }.getOrNull().orEmpty()
    val after = runCatching { connection.getTextAfterCursor(1, 0)?.toString() }.getOrNull().orEmpty()
    val prepared = TextInsertion.preparedTranscript(transcript, before, after)
    return runCatching { connection.commitText(prepared, 1) }.getOrDefault(false)
}
