package com.vocahq.vocaphone.local

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SherpaLongAudioTest {
    @Test
    fun `short audio keeps one no-copy decode range`() {
        val chunks = SherpaLongAudio.chunks(FloatArray(12 * SherpaLongAudio.SAMPLE_RATE))

        assertEquals(listOf(SherpaAudioChunk(0, 192_000, false)), chunks)
    }

    @Test
    fun `continuous long audio is bounded and overlaps only fallback boundaries`() {
        val samples = FloatArray(52 * SherpaLongAudio.SAMPLE_RATE) { 0.2f }

        val chunks = SherpaLongAudio.chunks(samples)

        assertTrue(chunks.size >= 3)
        assertTrue(chunks.all { it.endExclusive - it.start <= 14 * SherpaLongAudio.SAMPLE_RATE })
        assertTrue(chunks.drop(1).all { it.overlapsPrevious })
        assertTrue(chunks.zipWithNext().all { (left, right) -> right.start < left.endExclusive })
        assertEquals(samples.size, chunks.last().endExclusive)
    }

    @Test
    fun `the physical-device eighteen second regression is never one decode`() {
        val samples = FloatArray(18 * SherpaLongAudio.SAMPLE_RATE) { 0.2f }

        val chunks = SherpaLongAudio.chunks(samples)

        assertTrue(chunks.size >= 2)
        assertTrue(chunks.all { it.endExclusive - it.start <= 12 * SherpaLongAudio.SAMPLE_RATE })
        assertEquals(samples.size, chunks.last().endExclusive)
    }

    @Test
    fun `a quiet boundary avoids overlap`() {
        val samples = FloatArray(52 * SherpaLongAudio.SAMPLE_RATE) { 0.2f }
        val silenceStart = 9 * SherpaLongAudio.SAMPLE_RATE
        val silenceEnd = silenceStart + SherpaLongAudio.SAMPLE_RATE
        java.util.Arrays.fill(samples, silenceStart, silenceEnd, 0f)

        val first = SherpaLongAudio.chunks(samples).first()

        assertFalse(first.overlapsPrevious)
        assertTrue(first.endExclusive in silenceStart..silenceEnd)
    }

    @Test
    fun `streaming waits for lookahead and retains overlap for continuous speech`() {
        val tooEarly = FloatArray(11 * SherpaLongAudio.SAMPLE_RATE) { 0.2f }
        assertEquals(null, SherpaLongAudio.nextStreamingSplit(tooEarly))

        val ready = FloatArray(SherpaLongAudio.STREAMING_WINDOW_SECONDS * SherpaLongAudio.SAMPLE_RATE) {
            0.2f
        }
        val split = checkNotNull(SherpaLongAudio.nextStreamingSplit(ready))

        assertEquals(10 * SherpaLongAudio.SAMPLE_RATE, split.endExclusive)
        assertEquals(
            split.endExclusive - SherpaLongAudio.OVERLAP_MILLIS * SherpaLongAudio.SAMPLE_RATE / 1_000,
            split.nextStart,
        )
    }

    @Test
    fun `incremental session decodes completed chunks before its final tail`() = runBlocking {
        val decodedSizes = mutableListOf<Int>()
        val outputs = ArrayDeque(listOf("one boundary", "boundary two", "two three"))
        val firstChunkDecoded = CompletableDeferred<Unit>()
        val session = SherpaIncrementalSession(
            scope = this,
            prepare = {},
            decode = { samples ->
                decodedSizes += samples.size
                SherpaTranscript(outputs.removeFirst())
                    .also { firstChunkDecoded.complete(Unit) }
            },
        )
        val frame = ShortArray(SherpaLongAudio.SAMPLE_RATE / 10) { 4_000 }
        repeat(120) { assertTrue(session.offer(frame)) }
        withTimeout(5_000) { firstChunkDecoded.await() }
        repeat(130) { assertTrue(session.offer(frame)) }

        assertEquals("one boundary two three", session.finish().transcript.text)
        assertEquals(3, decodedSizes.size)
        assertTrue(decodedSizes.dropLast(1).all { it <= 10 * SherpaLongAudio.SAMPLE_RATE })
        assertTrue(decodedSizes.last() < 10 * SherpaLongAudio.SAMPLE_RATE)
    }

    @Test
    fun `an empty long chunk retries as two short decodes`() {
        val decodedSizes = mutableListOf<Int>()
        var shortResult = 0
        val transcript = SherpaEmptyChunkRecovery.decode(
            samples = FloatArray(10 * SherpaLongAudio.SAMPLE_RATE),
            decodeOnce = { samples ->
                decodedSizes += samples.size
                SherpaTranscript(
                    if (samples.size > 6 * SherpaLongAudio.SAMPLE_RATE) {
                        ""
                    } else if (shortResult++ == 0) {
                        "first half"
                    } else {
                        "second half"
                    },
                )
            },
        )

        assertEquals("first half second half", transcript.text)
        assertEquals(listOf(160_000, 80_000, 80_000), decodedSizes)
    }

    @Test
    fun `overlapped words are merged once`() {
        assertEquals(
            "hello world again",
            SherpaTranscriptMerger.append("hello world", "world again"),
        )
        assertEquals(
            "Hello, there.",
            SherpaTranscriptMerger.append("Hello", "Hello, there."),
        )
        assertEquals(
            "yes yes",
            SherpaTranscriptMerger.append("yes", "yes", deduplicateOverlap = false),
        )
    }
}
