package com.vocahq.vocaphone.ime

import kotlin.math.hypot

/**
 * Decides what one touch on the space bar means, kept free of Compose so the
 * cases can be tested against each other; `spacebarGesture` only feeds it
 * pointer positions and the two timers.
 *
 * - A tap types a space, and so does a tap that slides before [ARM_MS],
 *   however far: a space typed in a hurry is still a space.
 * - A still hold of [ARM_MS] arms the trackpad. Lifting then types nothing.
 *   Moving sideways moves the cursor by characters, faster for a faster
 *   finger ([gain]); moving a line height up or down sends a line step.
 * - Still for [PICKER_MS] from the press and not moved since arming: the
 *   system keyboard picker, which the hold used to open on its own.
 * - With more than one typing layout on ([layoutSwipePx] > 0), a sideways
 *   swipe before the hold arms changes layout, once per touch, and types no
 *   space. This is iOS's rule (`KeyGridView.handleSpaceMovement`): the hold
 *   is what separates the two gestures, so a cursor drag (hold, then slide)
 *   can never change layout and a swipe never moves the cursor. The swipe
 *   must cross [layoutSwipePx] (a quarter of the bar, clamped) and be more
 *   sideways than up, so the roll up toward `b` is not one.
 *
 * [stepPx] is the slow-finger drag per character and [lineStepPx] per line;
 * [slopPx] is how far a finger may wander and still count as still;
 * [pxPerDp] turns pixel speed into the dp/s [gain] is defined in.
 */
internal class SpacebarGesture(
    private val stepPx: Float,
    private val lineStepPx: Float,
    private val slopPx: Float,
    private val pxPerDp: Float,
    private val downX: Float,
    private val downY: Float,
    downTimeMs: Long,
    /** "Space-bar cursor control". Off, a hold never arms; held still, it opens the picker. */
    private val cursorEnabled: Boolean = true,
    /** Sideways travel that changes layout; 0 when there is only one layout. */
    private val layoutSwipePx: Float = 0f,
) {
    /** Cursor steps for one pointer move, and a layout change (+1 next, -1 previous). */
    data class Step(val characters: Int, val lines: Int, val layout: Int = 0) {
        val isEmpty: Boolean get() = characters == 0 && lines == 0 && layout == 0
    }

    /** The touch already changed layout; it does nothing else. */
    var switchedLayout = false
        private set

    var armed = false
        private set
    private var movedBeforeArming = false
    private var movedSinceArming = false
    private var pickerOpened = false
    private var armX = downX
    private var armY = downY
    private var lastX = downX
    private var lastY = downY
    private var lastTimeMs = downTimeMs
    private var speedDpPerSecond = 0f
    private var accumulatedX = 0f
    private var accumulatedY = 0f

    /** The [ARM_MS] timer fired. True when that arms the trackpad (a haptic). */
    fun armElapsed(): Boolean {
        if (!cursorEnabled || armed || movedBeforeArming || pickerOpened || switchedLayout) return false
        armed = true
        armX = lastX
        armY = lastY
        accumulatedX = 0f
        accumulatedY = 0f
        return true
    }

    /** The [PICKER_MS] timer fired. True when that opens the keyboard picker. */
    fun pickerElapsed(): Boolean {
        if (!cursorEnabled) {
            if (movedBeforeArming || pickerOpened) return false
            pickerOpened = true
            return true
        }
        if (!armed || movedSinceArming || pickerOpened) return false
        pickerOpened = true
        return true
    }

    fun move(x: Float, y: Float, timeMs: Long): Step {
        val dx = x - lastX
        val dy = y - lastY
        val dt = (timeMs - lastTimeMs).coerceAtLeast(1L)
        lastX = x
        lastY = y
        lastTimeMs = timeMs
        if (!armed) {
            if (hypot(x - downX, y - downY) > slopPx) movedBeforeArming = true
            val travel = x - downX
            val rise = kotlin.math.abs(y - downY)
            if (
                layoutSwipePx > 0f && !switchedLayout && !pickerOpened &&
                kotlin.math.abs(travel) > layoutSwipePx && kotlin.math.abs(travel) > rise
            ) {
                switchedLayout = true
                return Step(0, 0, layout = if (travel > 0) 1 else -1)
            }
            return NONE
        }
        if (pickerOpened) return NONE
        if (hypot(x - armX, y - armY) > slopPx) movedSinceArming = true
        val instant = hypot(dx, dy) / pxPerDp.coerceAtLeast(0.01f) * 1000f / dt
        speedDpPerSecond = speedDpPerSecond * 0.5f + instant * 0.5f
        val gain = gain(speedDpPerSecond)
        accumulatedX += dx * gain
        accumulatedY += dy * gain
        val characters = (accumulatedX / stepPx).toInt()
        val lines = (accumulatedY / lineStepPx).toInt()
        accumulatedX -= characters * stepPx
        accumulatedY -= lines * lineStepPx
        return if (characters == 0 && lines == 0) NONE else Step(characters, lines)
    }

    /** The finger lifted. True when that types a space. */
    fun release(): Boolean = !armed && !pickerOpened && !switchedLayout

    companion object {
        const val ARM_MS = 350L
        const val PICKER_MS = 1_000L

        /** Drag per character for a slow finger, and per line, in dp. */
        const val STEP_DP = 12f
        const val LINE_STEP_DP = 20f

        /** iOS's layout-swipe distance: a quarter of the bar, between 28 and 44 dp. */
        const val LAYOUT_SWIPE_MIN_DP = 28f
        const val LAYOUT_SWIPE_MAX_DP = 44f

        fun layoutSwipePx(barWidthPx: Float, pxPerDp: Float): Float =
            (barWidthPx / 4f).coerceIn(LAYOUT_SWIPE_MIN_DP * pxPerDp, LAYOUT_SWIPE_MAX_DP * pxPerDp)

        private val NONE = Step(0, 0)

        private val SPEEDS = floatArrayOf(0f, 400f, 1_000f, 2_000f)
        private val GAINS = floatArrayOf(1f, 1.4f, 2f, 2.6f)

        /** Characters per dp of travel at [dpPerSecond], relative to a slow finger. */
        fun gain(dpPerSecond: Float): Float {
            if (dpPerSecond <= SPEEDS.first()) return GAINS.first()
            for (index in 1 until SPEEDS.size) {
                if (dpPerSecond <= SPEEDS[index]) {
                    val t = (dpPerSecond - SPEEDS[index - 1]) / (SPEEDS[index] - SPEEDS[index - 1])
                    return GAINS[index - 1] + t * (GAINS[index] - GAINS[index - 1])
                }
            }
            return GAINS.last()
        }
    }
}
