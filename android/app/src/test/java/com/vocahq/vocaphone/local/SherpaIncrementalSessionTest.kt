package com.vocahq.vocaphone.local

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
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

    /**
     * A quiet speaker -- a phone on the desk -- whose later windows sit under
     * the silence floor raw but well above it at the gain the recording earns.
     * The complete-WAV path levels first and decodes them; the streaming path
     * used to judge them raw and skip them, losing their words from a result
     * that still looked safe.
     */
    @Test
    fun `quiet speech is judged at the level the model hears`() {
        var calls = 0
        // 600 is 0.018 RMS; 150 is 0.0046, under the 0.006 floor until the
        // eight-fold gain this recording earns lifts it to 0.037.
        val outcome = outcomeOf(frames(250) { if (it < 120) 600 else 150 }) {
            calls++
            SherpaTranscript("part $calls")
        }

        assertFalse(outcome.conditioningChanged)
        assertTrue(outcome.isSafe)
        assertEquals(3, calls)
        assertEquals("part 1 part 2 part 3", outcome.transcript.text)
    }

    @Test
    fun `near-digital silence is still never decoded`() {
        var calls = 0
        val outcome = outcomeOf(frames(250) { if (it < 120) 8_000 else 20 }) {
            calls++
            SherpaTranscript("part $calls")
        }

        // The loud opening and the window that straddles it are decoded; the
        // tail, levelled or not, is nothing a model should be asked about.
        assertEquals(2, calls)
        assertTrue(outcome.isSafe)
    }
}
