package com.vocahq.vocaphone.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class CueTimingTest {

    @Test
    fun `a cue still sounding delays the ready signal`() {
        assertEquals(600L, CueTiming.waitMillis(cueQuietAtMillis = 1_600, nowMillis = 1_000))
    }

    @Test
    fun `warm-up that outlasted the cue costs nothing`() {
        assertEquals(0L, CueTiming.waitMillis(cueQuietAtMillis = 1_200, nowMillis = 1_400))
    }

    @Test
    fun `the off tone never waits`() {
        // startCue returns "now" for anything that did not sound.
        assertEquals(0L, CueTiming.waitMillis(cueQuietAtMillis = 5_000, nowMillis = 5_000))
    }

    @Test
    fun `level measurement starts after the cue and its boundary frame`() {
        assertEquals(
            4_800,
            CueTiming.conditioningStartSample(
                cueOverlapSamples = 3_200,
                frameSamples = 1_600,
                cuePlayed = true,
            ),
        )
    }

    @Test
    fun `a silent cue skips no speech for level measurement`() {
        assertEquals(
            0,
            CueTiming.conditioningStartSample(
                cueOverlapSamples = 0,
                frameSamples = 1_600,
                cuePlayed = false,
            ),
        )
    }
}
