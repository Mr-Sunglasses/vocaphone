package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.DictationPhase

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
     * Visible X whenever dictation is running, listening included: discarding
     * used to mean Stop and then X, or a long-press nobody found. It sits at
     * the leading edge, across the strip from Stop, so a tap reaching for Stop
     * cannot land on it. Long-pressing Stop still discards too.
     */
    fun showsSeparateCancel(phase: DictationPhase): Boolean = phase.isBusy

    /** Menu, clipboard, and models stay reachable unless dictation is actually running. */
    fun allowsMenu(phase: DictationPhase): Boolean = !phase.isBusy
}
