package com.example.localflow.android.core

/**
 * The single place that decides whether the bubble is on screen. The bubble
 * lives with the keyboard: it appears when the user's own IME is open over an
 * eligible field, and leaves when the keyboard does. Extracted from the service
 * so every combination can be unit-tested.
 */
object BubblePolicy {

    enum class Decision { SHOW, HIDE }

    fun decide(
        /** The user's bubble setting; OFF always wins. */
        bubbleEnabled: Boolean,
        /** A dictation in flight keeps its bubble even across app switches. */
        dictationBusy: Boolean,
        /** Whether the user's keyboard is currently on screen. */
        imeVisible: Boolean,
        /** Whether the focused field is editable, safe, and not excluded. */
        fieldEligible: Boolean,
        /** Long-press snooze is still active. */
        snoozed: Boolean,
        /** The user tapped ✕; cleared the next time the keyboard closes. */
        dismissed: Boolean,
    ): Decision = when {
        !bubbleEnabled -> Decision.HIDE
        // Never pull the bubble out from under an active dictation: the user
        // needs Finish and Cancel wherever they have wandered.
        dictationBusy -> Decision.SHOW
        snoozed || dismissed -> Decision.HIDE
        imeVisible && fieldEligible -> Decision.SHOW
        else -> Decision.HIDE
    }
}
