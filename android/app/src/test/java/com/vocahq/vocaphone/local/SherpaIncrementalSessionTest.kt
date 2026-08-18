package com.vocahq.vocaphone.local

import kotlin.math.abs
import kotlin.math.sin
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The incremental path decodes a long recording as chunks while the microphone
 * is still open, so a chunk that comes back with no tokens takes its seconds out
 * of the transcript without leaving a trace in the text. These cover the two
 * things that keep those seconds: the caller is told, and the model is not
 * handed audio quieter than the whole-file path would give it.
 *
 * Mirrors the iOS client's `SherpaIncrementalSessionTests`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SherpaIncrementalSessionTest {

    /**
     * Speech-shaped enough to clear the silence floor, at whatever level the
     * microphone is being asked to imitate.
     */
    private fun tone(seconds: Double, amplitude: Float): ShortArray {
        val count = (SherpaLongAudio.SAMPLE_RATE * seconds).toInt()
        return ShortArray(count) { index ->
            val envelope = 0.4f + 0.6f * abs(sin(index * 0.0004f))
            (amplitude * sin(index * 0.08f) * envelope * 32_767f).toInt().toShort()
        }
    }

    private suspend fun run(
        samples: ShortArray,
        scope: TestScope,
        decode: (FloatArray) -> SherpaTranscript,
    ): SherpaIncrementalResult {
        val session = SherpaIncrementalSession(
            scope = scope,
            prepare = {},
            decode = { decode(it) },
        )
        var index = 0
        while (index < samples.size) {
            val end = minOf(index + 1_600, samples.size)
            assertTrue(session.offer(samples.copyOfRange(index, end)))
            index = end
        }
        return session.finish()
    }

    /** Room between sentences: above the near-silence floor, as a real room is. */
    private fun room(seconds: Double): ShortArray {
        val count = (SherpaLongAudio.SAMPLE_RATE * seconds).toInt()
        return ShortArray(count) { if (it % 2 == 0) 262 else -262 }
    }

    /**
     * What a transducer does: words for a chunk with speech in it, nothing for
     * a chunk of room tone. Reads the levelled audio the session hands over,
     * where speech has been brought to the 0.85 target and a pause has not.
     */
    private fun healthyModel(chunk: FloatArray): SherpaTranscript {
        val peak = chunk.fold(0f) { loudest, sample -> maxOf(loudest, abs(sample)) }
        return SherpaTranscript(if (peak > 0.3f) "spoken" else "")
    }

    @Test
    fun aHealthyModelNeverPaysForASecondPass() = runTest {
        // Every shape an ordinary dictation takes. None of them may set the
        // flag: it costs the whole recording decoded again at finish, which is
        // the entire wait this path exists to remove, and the fast families pay
        // most of their finish time to it.
        val shapes = listOf(
            "one sentence" to tone(seconds = 5.0, amplitude = 0.4f),
            "past a boundary" to tone(seconds = 22.0, amplitude = 0.4f),
            "left running after the last word" to
                tone(seconds = 20.0, amplitude = 0.4f) + room(seconds = 10.0),
            "a long pause to think" to
                tone(seconds = 10.0, amplitude = 0.4f) + room(seconds = 12.0) +
                tone(seconds = 10.0, amplitude = 0.4f),
            "unbroken" to tone(seconds = 40.0, amplitude = 0.4f),
        )

        for ((name, samples) in shapes) {
            val result = run(samples, this) { healthyModel(it) }

            assertFalse("$name asked for a second pass", result.droppedAudibleChunk)
            assertTrue("$name lost its words", result.transcript.text.startsWith("spoken"))
        }
    }

    @Test
    fun aChunkThatDecodesToNothingIsReported() = runTest {
        var decoded = 0
        val result = run(tone(seconds = 25.0, amplitude = 0.4f), this) {
            decoded += 1
            // Exactly the failure this exists for: the first long chunk comes
            // back empty and every later one succeeds, so the merged text reads
            // as a whole sentence that starts ten seconds in.
            if (decoded == 1) SherpaTranscript("") else SherpaTranscript("later")
        }

        assertTrue(decoded > 1)
        assertEquals("later", result.transcript.text)
        assertTrue(result.droppedAudibleChunk)
    }

    @Test
    fun aCompleteRunReportsNothingDropped() = runTest {
        val result = run(tone(seconds = 25.0, amplitude = 0.4f), this) {
            SherpaTranscript("spoken")
        }

        assertFalse(result.droppedAudibleChunk)
        assertTrue(result.transcript.text.startsWith("spoken"))
    }

    @Test
    fun silenceIsNotMistakenForADroppedChunk() = runTest {
        val result = run(ShortArray(SherpaLongAudio.SAMPLE_RATE * 25), this) {
            SherpaTranscript("")
        }

        // Nothing was said, so nothing was lost, and a whole-file retry of the
        // same silence would only cost the user time.
        assertTrue(result.transcript.text.isEmpty())
        assertFalse(result.droppedAudibleChunk)
    }

    @Test
    fun quietChunksReachTheModelLevelled() = runTest {
        val peaks = mutableListOf<Float>()
        run(tone(seconds = 25.0, amplitude = 0.05f), this) { chunk ->
            peaks += chunk.fold(0f) { peak, sample -> maxOf(peak, abs(sample)) }
            SherpaTranscript("spoken")
        }

        // A phone on a desk records far below what an int8 model was trained
        // on. The whole-file path has always levelled that; the streaming path
        // used to hand the model the raw 0.05.
        assertTrue(peaks.isNotEmpty())
        assertTrue(peaks.all { it > 0.3f })
    }

    @Test
    fun theGainComesFromTheRecordingAndNotFromTheChunk() = runTest {
        // Loud speech, then a passage far quieter but still plainly speech.
        val loud = tone(seconds = 13.0, amplitude = 0.5f)
        val quiet = tone(seconds = 16.0, amplitude = 0.03f)
        val peaks = mutableListOf<Float>()
        run(loud + quiet, this) { chunk ->
            peaks += chunk.fold(0f) { peak, sample -> maxOf(peak, abs(sample)) }
            SherpaTranscript("spoken")
        }

        // The quiet passage keeps its place under the loud one. Levelling it on
        // its own peak would have pushed it to the 0.85 target, which is how a
        // pause becomes noise the model transcribes as words.
        assertTrue(peaks.size > 1)
        assertTrue(peaks.last() > 0.03f)
        assertTrue(peaks.last() < 0.1f)
    }

    @Test
    fun aShortTailThatDecodesToNothingIsNotADroppedChunk() = runTest {
        val sizes = mutableListOf<Int>()
        val result = run(tone(seconds = 22.0, amplitude = 0.4f), this) { chunk ->
            sizes += chunk.size
            // A recording that ends just after a boundary leaves the half
            // second of retained overlap and a fragment of a word behind, and
            // that answers with no tokens all the time.
            if (chunk.size < 6 * SherpaLongAudio.SAMPLE_RATE) {
                SherpaTranscript("")
            } else {
                SherpaTranscript("spoken")
            }
        }

        assertTrue(sizes.last() < 6 * SherpaLongAudio.SAMPLE_RATE)
        // Calling that a loss re-runs the whole recording through the model at
        // finish, which is the exact wait the streaming path exists to remove.
        assertFalse(result.droppedAudibleChunk)
    }

    @Test
    fun aPauseInTheMiddleOfARecordingIsNotADroppedChunk() = runTest {
        // Room tone loud enough to clear the near-silence floor, which is what
        // a real room sounds like between two sentences. It is decoded, because
        // skipping it would risk skipping quiet speech -- but it decoding to
        // nothing is the right answer, not a loss.
        val speech = tone(seconds = 13.0, amplitude = 0.4f)
        val roomTone = ShortArray(SherpaLongAudio.SAMPLE_RATE * 16) { index ->
            if (index % 2 == 0) 655 else -655
        }
        var decoded = 0
        val result = run(speech + roomTone, this) {
            decoded += 1
            if (decoded > 2) SherpaTranscript("") else SherpaTranscript("spoken")
        }

        assertEquals(3, decoded)
        assertFalse(result.droppedAudibleChunk)
    }

    @Test
    fun theWholeFileRetryIsOnlyTakenWhenItRecoveredSomething() {
        val streamed = SherpaIncrementalResult(
            transcript = SherpaTranscript("the opening half and the rest of it"),
            droppedAudibleChunk = true,
        )

        assertTrue(streamed.supersededBy("the opening half and the rest of it, and more"))
        // The retry lost the opening half, which is the failure it was asked to
        // fix. Shipping it would cut a sentence the user watched being said.
        assertFalse(streamed.supersededBy("the rest of it"))
        assertFalse(streamed.supersededBy(""))
    }

    @Test
    fun trailingRoomToneIsNeitherDecodedNorCountedAsALoss() = runTest {
        // Quiet speech, so the levelling gain reaches its eight-times ceiling --
        // enough to lift room tone over a threshold meant for capture levels.
        val speech = tone(seconds = 13.0, amplitude = 0.05f)
        val roomTone = ShortArray(SherpaLongAudio.SAMPLE_RATE * 16) { index ->
            if (index % 2 == 0) 65 else -65
        }
        var decoded = 0
        val result = run(speech + roomTone, this) {
            decoded += 1
            if (decoded > 2) SherpaTranscript("") else SherpaTranscript("spoken")
        }

        // Nothing was said over those ten seconds, so there was nothing to
        // lose, and asking the model anyway costs a decode plus the two the
        // empty-chunk recovery would add on top.
        assertEquals(2, decoded)
        assertFalse(result.droppedAudibleChunk)
    }
}
