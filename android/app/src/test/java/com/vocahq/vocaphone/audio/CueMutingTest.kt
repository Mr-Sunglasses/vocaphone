package com.vocahq.vocaphone.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CueMutingTest {

    @Test
    fun `a cue still sounding is waited out`() {
        assertEquals(600L, CueMuting.waitMillis(cueQuietAtMillis = 1_600, nowMillis = 1_000))
    }

    @Test
    fun `warm-up that outlasted the cue costs nothing`() {
        assertEquals(0L, CueMuting.waitMillis(cueQuietAtMillis = 1_200, nowMillis = 1_400))
    }

    @Test
    fun `the off tone never waits`() {
        // startCue returns "now" for anything that did not sound.
        assertEquals(0L, CueMuting.waitMillis(cueQuietAtMillis = 5_000, nowMillis = 5_000))
    }

    @Test
    fun `frames under the cue are dropped and frames after it are kept`() {
        assertFalse(CueMuting.keepsFrame(frameAtMillis = 999, cueQuietAtMillis = 1_000))
        assertTrue(CueMuting.keepsFrame(frameAtMillis = 1_000, cueQuietAtMillis = 1_000))
        assertTrue(CueMuting.keepsFrame(frameAtMillis = 1_001, cueQuietAtMillis = 1_000))
    }

    @Test
    fun `no frame is dropped once the wait has been served`() {
        // The invariant the fix rests on: the user is told to speak at
        // `cueQuietAt`, and every frame from that mark on is kept.
        val cueQuietAt = 2_000L
        val announcedAt = cueQuietAt + CueMuting.waitMillis(cueQuietAt, cueQuietAt)

        assertTrue(CueMuting.keepsFrame(announcedAt, cueQuietAt))
    }
}
