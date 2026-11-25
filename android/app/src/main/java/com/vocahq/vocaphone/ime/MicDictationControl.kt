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

    /** A still hold this long on an idle mic starts push-to-talk. */
    const val HOLD_MS = 350L

    /** Sliding this far before the hold fires opens the menu instead. */
    const val SLIDE_DP = 10f
}

/** What one press on the mic key turned out to be. */
internal enum class MicPressEvent {
    /** A plain tap: [MicDictationControl.tap]. */
    TAP,

    /** Held still on an idle mic: start dictating now. */
    HOLD_START,

    /** The finger lifted after [HOLD_START]: finish, as tapping Stop does. */
    HOLD_END,

    /** Slid off before the hold fired: the style and language menu. */
    OPEN_MENU,

    /** Long-pressed while busy: discard, as before. */
    CANCEL,
}

/**
 * One press on the mic key, decided from the phase it went down in.
 *
 * Idle (a tap would start), the key is push-to-talk: a still hold of
 * [MicDictationControl.HOLD_MS] starts dictating and lifting finishes it; a
 * slide of more than [slopPx] before that opens the menu ([menuAllowed]); a
 * quick tap is the tap it always was. Busy, a long press still discards. Any
 * other phase only taps.
 */
internal class MicPress(
    private val phase: DictationPhase,
    private val menuAllowed: Boolean,
    private val slopPx: Float,
) {
    private val idle = MicDictationControl.tap(phase) == MicDictationAction.START
    private var moved = false
    private var holding = false
    private var menuOpened = false
    private var cancelled = false

    /** The finger is ([dx], [dy]) from where it went down. */
    fun move(dx: Float, dy: Float): MicPressEvent? {
        if (!idle || holding || menuOpened || moved) return null
        if (dx * dx + dy * dy <= slopPx * slopPx) return null
        moved = true
        if (!menuAllowed) return null
        menuOpened = true
        return MicPressEvent.OPEN_MENU
    }

    /** [MicDictationControl.HOLD_MS] passed with the finger down. */
    fun holdElapsed(): MicPressEvent? {
        if (!idle || moved || holding) return null
        holding = true
        return MicPressEvent.HOLD_START
    }

    /** The system long-press timeout passed with the finger down. */
    fun longPressElapsed(): MicPressEvent? {
        if (idle || cancelled || MicDictationControl.longPress(phase) != MicDictationAction.CANCEL) return null
        cancelled = true
        return MicPressEvent.CANCEL
    }

    fun release(): MicPressEvent? = when {
        holding -> MicPressEvent.HOLD_END
        menuOpened || moved || cancelled -> null
        else -> MicPressEvent.TAP
    }
}
