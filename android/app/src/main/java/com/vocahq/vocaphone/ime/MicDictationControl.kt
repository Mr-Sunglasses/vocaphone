package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.DictationPhase

/** What the keyboard mic does on tap vs long-press. */
internal enum class MicDictationAction {
    START,
    FINISH,
    CANCEL,

    /**
     * Ask whether the repair still stands and start if it does not; open the
     * page that fixes it if it does.
     */
    RECHECK_SETUP,

    /** Nothing: the spinner is a status, and discarding is the X. */
    NONE,
}

internal object MicDictationControl {
    /**
     * A tap on the spinner used to cancel the dictation and delete its
     * recording -- a tap that, on the bubble, does nothing. Discarding is the
     * X beside it now, so the spinner is inert.
     *
     * A repair used to open the app on every tap, even after the permission it
     * asked for had been granted: nothing re-checked it. The tap re-checks.
     */
    fun tap(phase: DictationPhase): MicDictationAction = when {
        phase == DictationPhase.LISTENING -> MicDictationAction.FINISH
        phase.isBusy -> MicDictationAction.NONE
        phase == DictationPhase.PERMISSION_REPAIR -> MicDictationAction.RECHECK_SETUP
        else -> MicDictationAction.START
    }

    fun longPress(phase: DictationPhase): MicDictationAction? =
        if (phase.isBusy) MicDictationAction.CANCEL else null

    /**
     * Visible X whenever dictation is running, listening included: discarding
     * used to mean Stop and then X, or a long-press nobody found. It sits at
     * the leading edge, across the strip from Stop, so a tap reaching for Stop
     * cannot land on it. Long-pressing Stop still discards too.
     */
    fun showsSeparateCancel(phase: DictationPhase): Boolean = phase.isBusy

    /** Menu, clipboard, and models stay reachable unless dictation is actually running. */
    fun allowsMenu(phase: DictationPhase): Boolean = !phase.isBusy
}
