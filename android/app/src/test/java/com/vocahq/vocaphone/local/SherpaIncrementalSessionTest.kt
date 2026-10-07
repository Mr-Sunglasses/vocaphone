package com.vocahq.vocaphone.local

import kotlin.math.abs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
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

    /** 100 ms frames of a square wave at [amplitudeAt], with one louder sample every 20 ms. */
    private fun clickyFrames(count: Int, click: Int, amplitudeAt: (Int) -> Int): List<ShortArray> =
        frames(count, amplitudeAt).mapIndexed { index, frame ->
            if (index in CLICKY_FRAMES) {
                for (sample in frame.indices step 320) frame[sample] = click.toShort()
            }
            frame
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

    /**
     * The tap that started the dictation, or a knock on the desk, is the
     * loudest sample of many recordings. The complete-WAV path sets it aside
     * when it chooses the gain; the streaming path used to level by it, kept
     * the gain at 1, and skipped the quiet speech that followed as silence.
     */
    @Test
    fun `a loud tap does not stop quiet speech being levelled`() {
        var calls = 0
        val outcome = outcomeOf(
            frames(250) {
                when {
                    it == 0 -> 30_000
                    it < 120 -> 600
                    else -> 150
                }
            },
        ) {
            calls++
            SherpaTranscript("part $calls")
        }

        assertFalse(outcome.conditioningChanged)
        assertTrue(outcome.isSafe)
        assertEquals(3, calls)
        assertEquals("part 1 part 2 part 3", outcome.transcript.text)
    }

    /**
     * Speech a quarter as loud as what came before it is speech, whatever gain
     * each window happened to be levelled with. Brief clicks halve the gain
     * part-way through without moving it past the drift tolerance; the loudest
     * frame used to be stored at the first window's gain and compared with this
     * window's level at half of it, and an empty answer here was taken for a
     * pause instead of a loss.
     */
    @Test
    fun `an empty window is judged against earlier speech at one gain`() {
        // 1_638 is 0.05 RMS and 410 is 0.0125: a quarter, well over the 18%
        // that counts as speech. The clicks reach 0.2 and move the gain from
        // 8 to 4.25, but add nothing to any 100 ms frame's RMS.
        val outcome = outcomeOf(
            clickyFrames(250, click = 6_554) { if (it < 130) 1_638 else 410 },
        ) { samples ->
            if (samples.maxOf { abs(it) } > 0.1f) SherpaTranscript("words") else SherpaTranscript.EMPTY
        }

        assertFalse(outcome.conditioningChanged)
        assertTrue(outcome.droppedAudibleChunk)
        assertFalse(outcome.isSafe)
    }


    /**
     * A stand-in recognizer for audio made of [spoken] frames: each run of
     * loud audio is one word, named by its length in 100 ms frames, so a word
     * cut in half or decoded twice shows up in the text. Read in 50 ms steps,
     * because a split can land half way through a capture frame.
     */
    private fun wordsIn(samples: FloatArray): SherpaTranscript {
        val words = mutableListOf<String>()
        var run = 0
        fun close() {
            if (run > 0) words += WORDS.getOrElse(run / 2) { "?$run" }
            run = 0
        }
        for (step in 0 until samples.size / 800) {
            var sum = 0.0
            for (index in step * 800 until (step + 1) * 800) sum += samples[index] * samples[index]
            if (kotlin.math.sqrt(sum / 800) > 0.05) run++ else close()
        }
        close()
        return SherpaTranscript(words.joinToString(" "))
    }

    /** Frames for [words] (by name) with [gapFrames] of room tone between them. */
    private fun spoken(vararg words: String, gapFrames: Int = 3): List<Int> =
        words.flatMapIndexed { index, word ->
            val loud = List(WORDS.entries.single { it.value == word }.key) { 8_000 }
            if (index == 0) loud else List(gapFrames) { 30 } + loud
        }

    private fun quiet(frames: Int): List<Int> = List(frames) { 30 }

    @Test
    fun `a pause decodes what came before it while recording continues`() = runBlocking {
        val first = quiet(3) + spoken("alpha", "bravo", "charlie", "delta") + quiet(10)
        val second = spoken("echo", "alpha", "bravo") + quiet(3)
        val decoded = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val session = SherpaIncrementalSession(scope = scope, prepare = {}) { samples ->
                decoded += samples.size
                wordsIn(samples)
            }
            frames(first.size) { first[it] }.forEach { assertTrue(session.offer(it)) }
            // The first sentence is decoded during the pause, before Finish.
            withTimeout(5_000) { while (decoded.isEmpty()) delay(10) }
            assertEquals(1, decoded.size)

            frames(second.size) { second[it] }.forEach { assertTrue(session.offer(it)) }
            val outcome = session.finish()

            assertTrue(outcome.isSafe)
            assertEquals("alpha bravo charlie delta echo alpha bravo", outcome.transcript.text)
            // What is left for Finish is the second sentence, not the recording.
            assertEquals(2, decoded.size)
            assertTrue(decoded[1] < (second.size + 10) * 1_600)
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun `the stitched transcript matches one decode of the whole recording`() {
        val levels = quiet(2) + spoken("charlie", "alpha", "delta", "bravo") + quiet(9) +
            spoken("bravo", "echo", "charlie") + quiet(12) +
            spoken("delta", "delta", "alpha", "echo") + quiet(4)
        val whole = frames(levels.size) { levels[it] }
            .flatMap { frame -> frame.map { it / 32_768f } }
            .toFloatArray()

        val outcome = outcomeOf(frames(levels.size) { levels[it] }, ::wordsIn)

        assertTrue(outcome.isSafe)
        assertEquals(wordsIn(whole).text, outcome.transcript.text)
        assertEquals(
            "charlie alpha delta bravo bravo echo charlie delta delta alpha echo",
            outcome.transcript.text,
        )
    }

    @Test
    fun `speech without a pause is still decoded once at the end`() {
        var calls = 0
        val levels = quiet(2) + spoken("alpha", "bravo", "charlie", "delta", "echo", "alpha") + quiet(2)

        val outcome = outcomeOf(frames(levels.size) { levels[it] }) {
            calls++
            wordsIn(it)
        }

        assertEquals(1, calls)
        assertEquals("alpha bravo charlie delta echo alpha", outcome.transcript.text)
    }

    private companion object {
        val CLICKY_FRAMES = 120 until 130
        val WORDS = mapOf(3 to "alpha", 4 to "bravo", 5 to "charlie", 6 to "delta", 7 to "echo")
    }
}
