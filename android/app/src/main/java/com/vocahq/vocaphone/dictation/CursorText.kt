package com.vocahq.vocaphone.dictation

/** The text either side of the cursor, as the keyboard read it. Held in memory only. */
class CursorText(val before: String, val after: String)

/**
 * Reads at most `limit` characters either side of the cursor of the field a
 * keyboard dictation started in, or null when it cannot.
 *
 * Given to [DictationController] by the keyboard, which decides whether the
 * field may be read at all ([com.vocahq.vocaphone.core.ImeInputPolicy.allowsContextRead]).
 * The controller calls it once, off the main thread
 * (`InputConnection.getTextBeforeCursor` is a blocking Binder call, safe from
 * any thread on the keyboard's side), turns the text into
 * [com.vocahq.vocaphone.core.ContextTerms] and drops it.
 */
fun interface CursorTextReader {
    fun read(limit: Int): CursorText?
}
