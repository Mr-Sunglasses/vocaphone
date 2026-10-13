package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SpacebarGestureTest {
    private fun gesture() = SpacebarGesture(stepPx = STEP, slopPx = SLOP, downX = 100f, downY = 50f)

    @Test
    fun `a tap types one space`() {
        val g = gesture()
        assertTrue(g.release())
    }

    @Test
    fun `a still hold opens the picker and types no space`() {
        val g = gesture()
        assertEquals(0, g.move(102f, 51f))
        assertTrue(g.holdAllowed)
        assertTrue(g.holdElapsed())
        assertFalse(g.release())
    }

    @Test
    fun `the picker opens once per hold`() {
        val g = gesture()
        assertTrue(g.holdElapsed())
        assertFalse(g.holdElapsed())
    }

    @Test
    fun `moving past the slop cancels the hold`() {
        val g = gesture()
        assertEquals(0, g.move(100f + SLOP + 1f, 50f))
        assertFalse(g.holdAllowed)
        assertFalse(g.holdElapsed())
        // Wandered but never moved the cursor: still a space, as before.
        assertTrue(g.release())
    }

    @Test
    fun `vertical wander past the slop also cancels the hold`() {
        val g = gesture()
        g.move(100f, 50f + SLOP + 1f)
        assertFalse(g.holdElapsed())
    }

    @Test
    fun `a drag moves the cursor and types no space`() {
        val g = gesture()
        assertEquals(2, g.move(100f + STEP * 2.5f, 50f))
        assertEquals(-3, g.move(100f - STEP * 1f, 50f))
        assertFalse(g.holdElapsed())
        assertFalse(g.release())
    }

    @Test
    fun `after the picker opens the finger no longer moves the cursor`() {
        val g = gesture()
        assertTrue(g.holdElapsed())
        assertEquals(0, g.move(100f + STEP * 5f, 50f))
        assertFalse(g.release())
    }

    private companion object {
        const val STEP = 40f
        const val SLOP = 16f
    }
}
