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
     * Visible X next to the mic. Hidden while listening so a walking tap cannot
     * discard; the red Stop long-press is the discard path then.
     */
    fun showsSeparateCancel(phase: DictationPhase): Boolean =
        phase.isBusy && phase != DictationPhase.LISTENING

    /** Menu, clipboard, and models stay reachable unless dictation is actually running. */
    fun allowsMenu(phase: DictationPhase): Boolean = !phase.isBusy
}
