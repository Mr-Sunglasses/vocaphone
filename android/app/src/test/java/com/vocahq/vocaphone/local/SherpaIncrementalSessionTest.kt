package com.vocahq.vocaphone.local

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SherpaIncrementalSessionTest {

    /** 100 ms frames whose amplitude follows [amplitudeAt], as AudioCapture emits them. */
    private fun frames(count: Int, amplitudeAt: (Int) -> Int): List<ShortArray> =
        (0 until count).map { index ->
            val amplitude = amplitudeAt(index)
            ShortArray(1_600) { sample ->
                if (sample % 2 == 0) amplitude.toShort() else (-amplitude).toShort()
            }
        }

    private fun outcomeOf(
        frames: List<ShortArray>,
        decode: (FloatArray) -> SherpaTranscript,
    ): SherpaIncrementalResult = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val session = SherpaIncrementalSession(scope = scope, prepare = {}, decode = decode)
            frames.forEach { assertTrue(session.offer(it)) }
            session.finish()
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun `complete stable windows produce a usable latency result`() {
        val outcome = outcomeOf(frames(120) { 8_000 }) { SherpaTranscript("words") }

        assertTrue(outcome.isSafe)
    }

    @Test
    fun `a speaker getting gradually louder still avoids the whole-file decode`() {
        // The running peak rises across every window of a real recording. Only
        // the gain it derives decides whether the latency result is usable, and
        // over this range that gain barely moves.
        val outcome = outcomeOf(frames(250) { 8_000 + it * 20 }) { SherpaTranscript("words") }

        assertFalse(outcome.conditioningChanged)
        assertTrue(outcome.isSafe)
    }

    @Test
    fun `a level jump big enough to change the gain forces the whole-file decode`() {
        val outcome = outcomeOf(frames(250) { if (it < 130) 800 else 20_000 }) {
            SherpaTranscript("words")
        }

        assertTrue(outcome.conditioningChanged)
        assertFalse(outcome.isSafe)
    }

    @Test
    fun `an empty audible window forces the complete wav fallback`() {
        val outcome = outcomeOf(frames(120) { 8_000 }) { SherpaTranscript.EMPTY }

        assertFalse(outcome.isSafe)
    }
}
