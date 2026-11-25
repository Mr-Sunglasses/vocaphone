package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SpacebarGestureTest {
    private fun gesture() = SpacebarGesture(
        stepPx = STEP,
        lineStepPx = LINE,
        slopPx = SLOP,
        pxPerDp = 1f,
        downX = 100f,
        downY = 50f,
        downTimeMs = 0L,
    )

    @Test
    fun `a tap types one space`() {
        assertTrue(gesture().release())
    }

    @Test
    fun `a tap that slides before the hold is still a space, however far`() {
        val g = gesture()
        assertEquals(SpacebarGesture.Step(0, 0), g.move(100f + STEP * 10f, 50f, 100L))
        assertFalse(g.armElapsed())
        assertTrue(g.release())
    }

    @Test
    fun `a still hold arms the trackpad and then types no space`() {
        val g = gesture()
        g.move(102f, 51f, 200L)
        assertTrue(g.armElapsed())
        assertFalse(g.release())
    }

    @Test
    fun `once armed, sideways moves the cursor by characters`() {
        val g = gesture()
        assertTrue(g.armElapsed())
        // Slow (a few dp a second): one character per step, the remainder kept.
        assertEquals(SpacebarGesture.Step(2, 0), g.move(100f + STEP * 2.5f, 50f, 100_000L))
        assertEquals(SpacebarGesture.Step(-3, 0), g.move(100f - STEP * 1f, 50f, 200_000L))
        assertFalse(g.release())
    }

    @Test
    fun `a faster finger moves further for the same distance`() {
        val slow = gesture().apply { armElapsed() }
        val fast = gesture().apply { armElapsed() }
        val slowSteps = slow.move(100f + STEP * 4f, 50f, 1_000L).characters
        val fastSteps = fast.move(100f + STEP * 4f, 50f, 10L).characters
        assertEquals(4, slowSteps)
        assertTrue("fast $fastSteps", fastSteps > slowSteps)
    }

    @Test
    fun `vertical movement of a line height steps a line`() {
        val g = gesture()
        assertTrue(g.armElapsed())
        assertEquals(SpacebarGesture.Step(0, 1), g.move(100f, 50f + LINE * 1.2f, 1_000L))
        assertEquals(SpacebarGesture.Step(0, -2), g.move(100f, 50f - LINE * 1f, 3_000L))
    }

    @Test
    fun `still for a second after arming opens the picker`() {
        val g = gesture()
        assertTrue(g.armElapsed())
        assertTrue(g.pickerElapsed())
        assertFalse(g.pickerElapsed())
        // The picker owns the rest of the touch.
        assertEquals(SpacebarGesture.Step(0, 0), g.move(100f + STEP * 5f, 50f, 1_500L))
        assertFalse(g.release())
    }

    @Test
    fun `moving after arming keeps the picker away`() {
        val g = gesture()
        assertTrue(g.armElapsed())
        g.move(100f + STEP * 2f, 50f, 600L)
        assertFalse(g.pickerElapsed())
    }

    @Test
    fun `the picker never opens without arming`() {
        val g = gesture()
        g.move(100f + SLOP * 2f, 50f, 100L)
        assertFalse(g.armElapsed())
        assertFalse(g.pickerElapsed())
        assertTrue(g.release())
    }

    @Test
    fun `gain follows the acceleration curve`() {
        assertEquals(1f, SpacebarGesture.gain(0f), 0.001f)
        assertEquals(1.4f, SpacebarGesture.gain(400f), 0.001f)
        assertEquals(2f, SpacebarGesture.gain(1_000f), 0.001f)
        assertEquals(2.6f, SpacebarGesture.gain(2_000f), 0.001f)
        assertEquals(2.6f, SpacebarGesture.gain(9_000f), 0.001f)
        assertEquals(1.2f, SpacebarGesture.gain(200f), 0.001f)
    }

    private companion object {
        const val STEP = 40f
        const val LINE = 60f
        const val SLOP = 16f
    }
}
