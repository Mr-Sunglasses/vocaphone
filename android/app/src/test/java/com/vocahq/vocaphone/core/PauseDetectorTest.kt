package com.vocahq.vocaphone.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The same cases as `PauseDetectorTests.swift`, in the 100 ms frames Android captures. */
class PauseDetectorTest {
    private fun PauseDetector.feed(rms: Float, seconds: Double): Boolean {
        var fired = false
        repeat(Math.round(seconds / 0.1).toInt()) { fired = observe(rms, 0.1) || fired }
        return fired
    }

    @Test
    fun `speech then three seconds of quiet finishes`() {
        val detector = PauseDetector()
        assertFalse(detector.feed(0.001f, 1.0))
        assertFalse(detector.feed(0.05f, 2.0))
        assertFalse(detector.feed(0.001f, 2.9))
        assertTrue(detector.feed(0.001f, 0.2))
    }

    @Test
    fun `a short pause does not finish`() {
        val detector = PauseDetector()
        detector.feed(0.001f, 1.0)
        detector.feed(0.05f, 2.0)
        assertFalse(detector.feed(0.001f, 2.0))
        assertFalse(detector.feed(0.05f, 0.5))
        assertFalse(detector.feed(0.001f, 2.5))
    }

    @Test
    fun `silence before speech never finishes`() {
        val detector = PauseDetector()
        assertFalse(detector.feed(0.001f, 10.0))
        assertFalse(detector.feed(0.05f, 0.5))
        assertFalse(detector.feed(0.001f, 5.0))
    }

    @Test
    fun `a fan switching on never ends the recording`() {
        val detector = PauseDetector()
        detector.feed(0.001f, 1.0)
        detector.feed(0.05f, 2.0)
        assertFalse(detector.feed(0.03f, 120.0))
    }

    @Test
    fun `quiet speech over background still stops`() {
        // About 9 dB apart: the background after the speech is still the pause.
        val detector = PauseDetector()
        detector.feed(0.001f, 1.0)
        detector.feed(0.02f, 2.0)
        assertTrue(detector.feed(0.007f, 3.2))
    }

    @Test
    fun `a noisy room is the floor`() {
        val detector = PauseDetector()
        assertFalse(detector.feed(0.02f, 5.0))
        assertFalse(detector.feed(0.15f, 2.0))
        assertTrue(detector.feed(0.02f, 3.1))
    }
}
