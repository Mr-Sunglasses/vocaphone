package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The timings that make the keyboard feel like the platform's, pinned to the
 * values AOSP LatinIME ships (java/res/values/config-common.xml) so a change
 * is a deliberate one.
 */
class KeyboardFeelTest {
    @Test
    fun longPressMatchesLatinImeAndGboard() {
        // config_default_longpress_key_timeout; Gboard's "Key long press delay" default.
        assertEquals(300L, AccentPicker.HOLD_MS)
    }

    @Test
    fun deleteRepeatMatchesLatinIme() {
        // config_key_repeat_start_timeout / config_key_repeat_interval.
        assertEquals(400L, DeleteHold.REPEAT_DELAY_MS)
        assertEquals(50L, DeleteHold.CHAR_INTERVAL_MS)
    }

    @Test
    fun doubleTapShiftWindowIsTheDoubleTapTimeout() {
        // LatinIME's TimerHandler uses ViewConfiguration.getDoubleTapTimeout(), 300 ms.
        assertEquals(300L, KeyboardReducer.CAPS_LOCK_WINDOW_MILLIS)
    }

    private fun spacebar(cursor: Boolean) = SpacebarGesture(
        stepPx = 40f,
        lineStepPx = 60f,
        slopPx = 16f,
        pxPerDp = 1f,
        downX = 100f,
        downY = 50f,
        downTimeMs = 0L,
        cursorEnabled = cursor,
    )

    @Test
    fun withCursorControlOffAHoldNeverArms() {
        val g = spacebar(cursor = false)
        assertFalse(g.armElapsed())
        assertEquals(SpacebarGesture.Step(0, 0), g.move(300f, 50f, 600L))
        assertTrue(g.release())
    }

    @Test
    fun withCursorControlOffAStillHoldStillOpensThePicker() {
        val g = spacebar(cursor = false)
        assertFalse(g.armElapsed())
        assertTrue(g.pickerElapsed())
        assertFalse(g.release())
    }

    @Test
    fun withCursorControlOffAMovedHoldIsASpace() {
        val g = spacebar(cursor = false)
        g.move(200f, 50f, 100L)
        assertFalse(g.pickerElapsed())
        assertTrue(g.release())
    }
}
