package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState

/** What the keyboard's dictation bar offers next to its status, besides the mic. */
internal enum class DictationBarAction(val label: String) {
    /** Re-send the recording a failure kept. The mic records a new one. */
    RETRY("Retry"),

    /** Put a transcript that was saved to History into this field. */
    INSERT("Insert"),
}

/**
 * The words in the keyboard's dictation bar and what TalkBack hears from it.
 *
 * Kept apart from the composables so the copy is testable and so the voice
 * shortcut's bar and the full keyboard's say the same thing.
 */
internal object DictationBarCopy {
    const val SAVED_TITLE = "Saved to History"
    const val ONE_MINUTE_LEFT = "1 minute left"

    fun status(state: DictationState, formattedDuration: String): String = when (state.phase) {
        DictationPhase.IDLE -> "VocaPhone"
        DictationPhase.LISTENING -> "Listening · $formattedDuration"
        DictationPhase.READY_TO_INSERT -> SAVED_TITLE
        DictationPhase.FAILED -> state.failure?.title ?: "Dictation failed"
        DictationPhase.PERMISSION_REPAIR -> state.repairTitle
        else -> state.statusText
    }

    /**
     * The second line. [busyDetail] is what to say while VocaPhone works: the
     * keyboard reminds people they can keep typing, the shortcut says nothing.
     */
    fun detail(state: DictationState, idleDetail: String, busyDetail: String): String = when {
        state.phase == DictationPhase.IDLE -> idleDetail
        // The bubble and the Dictate screen warned a minute before the cap
        // stopped the recording; the keyboard never did.
        state.phase == DictationPhase.LISTENING && state.approachingLimit -> ONE_MINUTE_LEFT
        state.phase == DictationPhase.LISTENING && state.partialTranscript.isNotBlank() ->
            state.partialTranscript.replace('\n', ' ').take(64)
        state.phase == DictationPhase.LISTENING ->
            state.inputRouteLabel ?: "Tap the red button to finish"
        state.phase.isBusy -> busyDetail
        state.phase == DictationPhase.PERMISSION_REPAIR -> state.repairAction
        state.phase == DictationPhase.FAILED -> state.failure?.message ?: "Tap the mic to dictate again"
        state.phase == DictationPhase.READY_TO_INSERT ->
            state.transcript.orEmpty().replace('\n', ' ').take(64)
        else -> "Ready"
    }

    /** True when the second line is a warning rather than information. */
    fun detailIsWarning(state: DictationState): Boolean =
        state.phase == DictationPhase.LISTENING && state.approachingLimit

    fun action(state: DictationState): DictationBarAction? = when {
        state.canRetry -> DictationBarAction.RETRY
        state.phase == DictationPhase.READY_TO_INSERT && !state.transcript.isNullOrBlank() ->
            DictationBarAction.INSERT
        else -> null
    }

    /**
     * What a screen reader announces, as a polite live region. Only changes of
     * phase: the status used to be a live region around the ticking timer,
     * the partial transcript and the suggestion strip, so TalkBack talked over
     * the person dictating every second. Null while idle, which has nothing to
     * announce.
     */
    fun announcement(state: DictationState): String? = when (state.phase) {
        DictationPhase.IDLE -> null
        DictationPhase.LISTENING ->
            if (state.approachingLimit) "Listening. $ONE_MINUTE_LEFT" else "Listening"
        DictationPhase.FINALIZING -> "Finishing"
        DictationPhase.UPLOADING -> "Sending to your gateway"
        DictationPhase.TRANSCRIBING -> "Transcribing"
        DictationPhase.INSERTING -> "Inserting"
        DictationPhase.INSERTED -> "Inserted"
        DictationPhase.READY_TO_INSERT -> SAVED_TITLE
        DictationPhase.FAILED -> listOfNotNull(state.failure?.title, state.failure?.message)
            .joinToString(". ")
            .ifEmpty { "Dictation failed" }
        DictationPhase.PERMISSION_REPAIR -> state.repairTitle
    }

    /** The mic's accessibility label; the spinner says it is not the way to cancel. */
    fun micDescription(state: DictationState, enabled: Boolean): String = when {
        !enabled -> "Dictation unavailable"
        state.phase == DictationPhase.LISTENING ->
            "Finish dictation. Long-press to discard without inserting"
        state.phase.isBusy -> "${state.statusText}. Use Cancel dictation to discard it"
        state.phase == DictationPhase.PERMISSION_REPAIR -> "${state.repairTitle}. ${state.repairAction}"
        state.phase == DictationPhase.FAILED || state.phase == DictationPhase.READY_TO_INSERT ->
            "Start a new dictation"
        else -> "Start dictation"
    }
}
