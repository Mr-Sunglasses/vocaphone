package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState

/** What the keyboard mic does on tap vs long-press. */
internal enum class MicDictationAction {
    START,
    FINISH,
    CANCEL,
    OPEN_APP,
}

internal object MicDictationControl {
    fun tap(phase: DictationPhase): MicDictationAction = when {
        phase == DictationPhase.LISTENING -> MicDictationAction.FINISH
        phase.isBusy -> MicDictationAction.CANCEL
        phase == DictationPhase.PERMISSION_REPAIR -> MicDictationAction.OPEN_APP
        else -> MicDictationAction.START
    }

    fun longPress(phase: DictationPhase): MicDictationAction? =
        if (phase.isBusy) MicDictationAction.CANCEL else null

    /**
     * Visible X next to the mic. Hidden while listening so a walking tap cannot
     * discard; the red Stop long-press is the discard path then.
     */
    fun showsSeparateCancel(phase: DictationPhase): Boolean =
        phase.isBusy && phase != DictationPhase.LISTENING

    /** Menu, clipboard, and models stay reachable unless dictation is actually running. */
    fun allowsMenu(phase: DictationPhase): Boolean = !phase.isBusy

    /**
     * Whether the mic should already look busy for a tap the controller has
     * not reflected yet.
     *
     * Start reaches LISTENING only after the service, AudioRecord and the cue;
     * Finish reaches FINALIZING only after capture drains and a gateway stream
     * closes. Both can take hundreds of milliseconds, well past the 100 ms in
     * which a tap has to visibly land (docs/latency.md). The haptic fires on
     * the tap; this is the picture that goes with it.
     *
     * [tapped] is the state the tap was decided on. Start waits through the
     * IDLE that clearing a previous result passes through; a FAILED or other
     * state from the same session is the old result, not this tap's answer.
     */
    fun awaitingTap(tapped: DictationState, current: DictationState): Boolean = when (tap(tapped.phase)) {
        MicDictationAction.START -> current.phase == DictationPhase.IDLE ||
            (current.phase == tapped.phase && current.sessionId == tapped.sessionId)
        MicDictationAction.FINISH -> current.phase == DictationPhase.LISTENING &&
            current.sessionId == tapped.sessionId
        else -> false
    }

    /** Gives up on a tap nothing answered, so the button cannot stay busy forever. */
    const val TAP_FEEDBACK_TIMEOUT_MILLIS = 5_000L
}
