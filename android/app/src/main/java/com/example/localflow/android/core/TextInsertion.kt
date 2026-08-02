package com.example.localflow.android.core

/**
 * Pure text arithmetic for direct insertion, kept away from Android types so the
 * splice and the undo rule can be tested exhaustively.
 */
object TextInsertion {

    data class Plan(
        /** The full field contents to hand to `ACTION_SET_TEXT`. */
        val updatedText: String,
        /** The transcript as it was actually written, including added spacing. */
        val inserted: String,
        val insertionStart: Int,
    ) {
        val cursor: Int get() = insertionStart + inserted.length
    }

    /**
     * An empty field reports its placeholder from `getText()`, so "Signal
     * message" or "Ask Google" would otherwise be spliced into the user's
     * message as if they had typed it. Not every editor sets the
     * showing-hint flag while doing this (WhatsApp's "Message" field does
     * not), so text that matches the field's own hint — ignoring case and
     * whitespace, since the two are reported through different paths — is
     * also placeholder.
     */
    fun fieldContents(text: String?, showingHintText: Boolean, hintText: String? = null): String {
        if (showingHintText) return ""
        val contents = text.orEmpty()
        if (contents.isBlank()) return ""
        if (hintText != null && normalizedForHintComparison(contents) == normalizedForHintComparison(hintText)) {
            return ""
        }
        return contents
    }

    private fun normalizedForHintComparison(value: String): String =
        value.filterNot(Char::isWhitespace).lowercase()

    /**
     * Splices [transcript] over the selection, adding the spacing a person would
     * have typed. Returns `null` when the transcript is blank or the selection is
     * not a range inside [existing].
     */
    fun plan(existing: String, selectionStart: Int, selectionEnd: Int, transcript: String): Plan? {
        val start = minOf(selectionStart, selectionEnd)
        val end = maxOf(selectionStart, selectionEnd)
        if (start < 0 || end > existing.length) return null

        val before = existing.substring(0, start)
        val after = existing.substring(end)
        val prepared = preparedTranscript(transcript, before, after)
        if (prepared.isEmpty()) return null

        return Plan(before + prepared + after, prepared, start)
    }

    /**
     * Mirrors the iOS spacing rule: separate the transcript from adjacent words,
     * but never from punctuation the user is dictating into.
     */
    fun preparedTranscript(transcript: String, before: String, after: String): String {
        var result = transcript.trim()
        if (result.isEmpty()) return result

        val previous = before.lastOrNull()
        if (previous != null && !previous.isWhitespace() && !isPunctuation(result.first())) {
            result = " $result"
        }

        val next = after.firstOrNull()
        if (next != null && !next.isWhitespace() && !isPunctuation(next) && !result.last().isWhitespace()) {
            result += " "
        }
        return result
    }

    /**
     * Removes a previous insertion, but only when the exact transcript still sits
     * where it was written. If the user or the app has since edited that text,
     * returns `null` so Undo is disabled rather than destroying their edit.
     */
    fun undo(current: String, insertionStart: Int, inserted: String): String? {
        if (inserted.isEmpty()) return null
        val end = insertionStart + inserted.length
        if (insertionStart < 0 || end > current.length) return null
        if (!current.regionMatches(insertionStart, inserted, 0, inserted.length)) return null
        return current.removeRange(insertionStart, end)
    }

    private fun isPunctuation(character: Char): Boolean = when (character.category) {
        CharCategory.CONNECTOR_PUNCTUATION,
        CharCategory.DASH_PUNCTUATION,
        CharCategory.START_PUNCTUATION,
        CharCategory.END_PUNCTUATION,
        CharCategory.INITIAL_QUOTE_PUNCTUATION,
        CharCategory.FINAL_QUOTE_PUNCTUATION,
        CharCategory.OTHER_PUNCTUATION,
        -> true

        else -> false
    }
}
