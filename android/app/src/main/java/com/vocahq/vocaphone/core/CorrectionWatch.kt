package com.vocahq.vocaphone.core

/**
 * A spelling the user fixed in a dictation, ready to be suggested. Only this
 * pair leaves the keyboard: never the text around it.
 *
 * [heardIsWord] and [namesTerm] are decided where the word list is loaded
 * (the keyboard), so whoever stores the pair needs no list of its own.
 */
data class LearnedCorrection(
    val heard: String,
    val corrected: String,
    /** [heard] is one ordinary word: learning it as a replacement would rewrite ordinary speech. */
    val heardIsWord: Boolean,
    /** [corrected] has a capital or a word the list doesn't know: a name or a term, not grammar. */
    val namesTerm: Boolean,
)

/**
 * Follows one dictation in the field it was typed into, and works out what
 * the user respelled in it ([CorrectionLearner]).
 *
 * The keyboard hands it what it already reads around the cursor as the user
 * edits. The first reading after the insertion is the baseline: the dictation
 * and the text either side of it. Each later reading finds the dictation
 * again by that surrounding text ([DictatedSpan]) and keeps what the learner
 * makes of it; a reading where it cannot be found — the message was sent and
 * the field cleared, the user moved on — leaves the last result standing.
 * [finish] hands that result over and forgets everything.
 *
 * Text is held in memory only, for one dictation, and never stored. Not
 * thread-safe: one caller at a time. Mirrors `CorrectionWatch.swift`.
 */
class CorrectionWatch(private val isKnownWord: (String) -> Boolean) {

    private var dictated: String? = null
    private var baseline: DictatedSpan? = null
    private var pending: List<LearnedCorrection> = emptyList()

    /** Whether a dictation is being followed. */
    val isActive: Boolean get() = dictated != null

    /**
     * Starts following [inserted], replacing any dictation followed before
     * (call [finish] first to keep what it found). Returns false, following
     * nothing, for text not worth it: blank, very long, or not in the
     * language the word list knows, where respelling and rewording cannot be
     * told apart.
     */
    fun start(inserted: String): Boolean {
        clear()
        val text = inserted.trim()
        if (text.isEmpty() || text.length > MAXIMUM_DICTATION) return false
        if (!CorrectionLearner.readsAsKnownLanguage(text, isKnownWord)) return false
        dictated = text
        return true
    }

    /**
     * One reading of the field around the cursor.
     *
     * @param reachesStart [before] begins at the start of the field.
     * @param reachesEnd [after] ends at the end of the field.
     */
    fun read(before: String, after: String, reachesStart: Boolean, reachesEnd: Boolean) {
        val text = dictated ?: return
        val span = baseline
        if (span == null) {
            // The first reading is taken just after the insertion, the cursor
            // at its end; a dictation not there was not inserted as expected.
            baseline = DictatedSpan.baseline(text, before, after, reachesStart, reachesEnd)
            if (baseline == null) clear()
            return
        }
        val found = span.corrections(before, after, reachesStart, reachesEnd, isKnownWord) ?: return
        pending = found.map { correction ->
            LearnedCorrection(
                heard = correction.heard,
                corrected = correction.corrected,
                heardIsWord = CorrectionLearner.isOrdinaryWord(correction.heard, isKnownWord),
                namesTerm = CorrectionLearner.namesATerm(correction.corrected, isKnownWord),
            )
        }
    }

    /** What the last reading that found the dictation learned, and stop following it. */
    fun finish(): List<LearnedCorrection> {
        val found = pending
        clear()
        return found
    }

    private fun clear() {
        dictated = null
        baseline = null
        pending = emptyList()
    }

    companion object {
        /** Longer dictations are documents, not messages, and not worth reading back. */
        const val MAXIMUM_DICTATION = 1_000

        /** Characters to read either side of the cursor while following [inserted]. */
        fun readLimit(inserted: String): Int =
            (inserted.trim().length + 2 * DictatedSpan.ANCHOR + 64).coerceAtMost(MAXIMUM_DICTATION + 2 * DictatedSpan.ANCHOR + 64)
    }
}

/**
 * Where a dictation sits in its field, told by the text either side of it,
 * so it can be found again after the user has edited it — and the cursor,
 * and with it the window of text the keyboard can read, has moved.
 *
 * [before] and [after] are the anchors: up to [ANCHOR] characters next to the
 * dictation. [beforeIsFieldStart] says the field starts where [before] does,
 * so the anchor must sit at the start of a reading that reaches the field's
 * start; likewise [afterIsFieldEnd].
 */
data class DictatedSpan(
    val dictated: String,
    val before: String,
    val after: String,
    val beforeIsFieldStart: Boolean,
    val afterIsFieldEnd: Boolean,
) {
    /**
     * What the learner makes of the dictation as the field now reads, or
     * null when it can't be found with confidence: an anchor is gone or
     * appears in more than one place with different text between, or what
     * is between no longer looks like the dictation edited.
     */
    fun corrections(
        windowBefore: String,
        windowAfter: String,
        reachesStart: Boolean,
        reachesEnd: Boolean,
        isKnownWord: (String) -> Boolean,
    ): List<CorrectionLearner.Correction>? {
        val edited = edited(windowBefore + windowAfter, reachesStart, reachesEnd) ?: return null
        val old = before + dictated + after
        val new = before + edited + after
        if (old == new) return emptyList()
        return CorrectionLearner.corrections(dictated, old, new, before.length + dictated.length, isKnownWord)
    }

    /** The dictation as it reads in [window] now; see [corrections]. */
    fun edited(window: String, reachesStart: Boolean, reachesEnd: Boolean): String? {
        val starts = anchorEnds(window, reachesStart)
        val ends = anchorStarts(window, reachesEnd)
        if (starts.isEmpty() || ends.isEmpty()) return null
        val longest = dictated.length * 2 + 40
        val regions = mutableSetOf<String>()
        // Only anchors that are each other's nearest: in repetitive text an
        // earlier copy of the left anchor, or a later one of the right, would
        // otherwise frame the dictation plus a sentence beside it.
        for (end in ends) {
            val start = starts.lastOrNull { it <= end } ?: continue
            if (ends.first { it >= start } != end || end - start > longest) continue
            val region = window.substring(start, end).trim()
            if (CorrectionLearner.isStillDictation(region, dictated)) regions += region
        }
        return regions.singleOrNull()
    }

    /** Offsets in [window] where the dictation could start. */
    private fun anchorEnds(window: String, reachesStart: Boolean): List<Int> {
        if (beforeIsFieldStart && reachesStart) {
            return if (window.startsWith(before)) listOf(before.length) else emptyList()
        }
        if (before.isEmpty()) return emptyList()
        return occurrences(before, window).map { it + before.length }
    }

    /** Offsets in [window] where the dictation could end. */
    private fun anchorStarts(window: String, reachesEnd: Boolean): List<Int> {
        if (afterIsFieldEnd && reachesEnd) {
            return if (window.endsWith(after)) listOf(window.length - after.length) else emptyList()
        }
        if (after.isEmpty()) return emptyList()
        return occurrences(after, window)
    }

    private fun occurrences(needle: String, haystack: String): List<Int> {
        val found = mutableListOf<Int>()
        var index = haystack.indexOf(needle)
        while (index >= 0 && found.size < MAXIMUM_OCCURRENCES) {
            found += index
            index = haystack.indexOf(needle, index + 1)
        }
        return found
    }

    companion object {
        /** Characters either side of the dictation that find it again. */
        const val ANCHOR = 24
        private const val MAXIMUM_OCCURRENCES = 8

        /**
         * The dictation in a reading taken just after it was typed, the cursor
         * at its end (a space after it allowed), or null when it isn't there.
         */
        fun baseline(
            dictated: String,
            windowBefore: String,
            windowAfter: String,
            reachesStart: Boolean,
            reachesEnd: Boolean,
        ): DictatedSpan? {
            val window = windowBefore + windowAfter
            val caret = windowBefore.length
            val range = CorrectionLearner.locate(dictated, window, caret) ?: return null
            if (caret - range.end !in 0..2) return null
            val fullBefore = window.substring(0, range.start)
            val fullAfter = window.substring(range.end)
            return DictatedSpan(
                dictated = dictated,
                before = fullBefore.takeLast(ANCHOR),
                after = fullAfter.take(ANCHOR),
                beforeIsFieldStart = reachesStart && fullBefore.length <= ANCHOR,
                afterIsFieldEnd = reachesEnd && fullAfter.length <= ANCHOR,
            )
        }
    }
}
