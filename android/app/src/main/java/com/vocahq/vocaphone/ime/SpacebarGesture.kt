package com.vocahq.vocaphone.ime

import kotlin.math.abs
import kotlin.math.hypot

/**
 * Decides what one touch on the space bar means: a tap types a space, a
 * horizontal drag moves the cursor, and a still hold opens the keyboard
 * picker. Kept free of Compose so the three can be tested against each other;
 * `spacebarGesture` only feeds it pointer positions and the hold timer.
 *
 * [stepPx] is the drag distance per cursor position, [slopPx] how far the
 * finger may wander before a hold no longer counts as still.
 */
internal class SpacebarGesture(
    private val stepPx: Float,
    private val slopPx: Float,
    private val downX: Float,
    private val downY: Float,
) {
    private var lastX = downX
    private var accumulated = 0f
    private var moved = false
    private var dragged = false
    private var longPressed = false

    /** False once the finger has left the slop or moved the cursor. */
    val holdAllowed: Boolean get() = !moved && !dragged && !longPressed

    /** Cursor positions to move for this pointer position; 0 for none. */
    fun move(x: Float, y: Float): Int {
        if (longPressed) {
            lastX = x
            return 0
        }
        if (hypot(x - downX, y - downY) > slopPx) moved = true
        accumulated += x - lastX
        lastX = x
        if (abs(accumulated) < stepPx) return 0
        val positions = (accumulated / stepPx).toInt()
        accumulated -= positions * stepPx
        dragged = true
        return positions
    }

    /** The hold timer fired. True when that should open the picker. */
    fun holdElapsed(): Boolean {
        if (!holdAllowed) return false
        longPressed = true
        return true
    }

    /** The finger lifted. True when that types a space. */
    fun release(): Boolean = !dragged && !longPressed
}
