package com.vocahq.vocaphone.audio

import kotlin.math.abs
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeechAudioConditioningTest {

    private fun tone(peak: Float, offset: Float = 0f, count: Int = 16_000) =
        FloatArray(count) { index -> (peak * sin(index * 0.05)).toFloat() + offset }

    private fun peak(samples: FloatArray) = samples.maxOf { abs(it) }

    @Test
    fun `a quiet recording is brought up to the target level`() {
        // 0.85/0.2 is well inside the gain ceiling, so the target is reached.
        val conditioned = SpeechAudioConditioning.condition(tone(peak = 0.2f))
        assertEquals(0.85f, peak(conditioned), 0.02f)
    }

    @Test
    fun `the boost is capped so a noise floor never becomes full scale`() {
        // 0.85/0.02 would be 42x; the ceiling is 8x.
        val conditioned = SpeechAudioConditioning.condition(tone(peak = 0.02f))
        assertEquals(0.16f, peak(conditioned), 0.01f)
    }

    @Test
    fun `an already loud recording is not amplified`() {
        val original = tone(peak = 0.95f)
        val conditioned = SpeechAudioConditioning.condition(original.copyOf())
        // Only the residual DC of a partial-period tone moves, never the gain.
        assertEquals(peak(original), peak(conditioned), 0.01f)
    }

    @Test
    fun `silence is left alone so it still reads as silence`() {
        val silence = FloatArray(16_000)
        assertEquals(0f, peak(SpeechAudioConditioning.condition(silence)), 0f)

        val nearSilence = tone(peak = 0.001f)
        assertTrue(peak(SpeechAudioConditioning.condition(nearSilence)) < 0.005f)
    }

    @Test
    fun `a dc offset is removed rather than amplified`() {
        val conditioned = SpeechAudioConditioning.condition(tone(peak = 0.1f, offset = 0.2f))
        val mean = conditioned.sum() / conditioned.size
        assertEquals(0f, mean, 0.01f)
    }

    @Test
    fun `an empty recording is handled`() {
        assertEquals(0, SpeechAudioConditioning.condition(FloatArray(0)).size)
    }

    @Test
    fun `a loud start cue does not prevent quiet speech from being levelled`() {
        val cue = tone(peak = 0.9f, count = 3_200)
        val speech = tone(peak = 0.1f, count = 16_000)
        val conditioned = SpeechAudioConditioning.condition(cue + speech, cue.size)

        val speechPeak = conditioned.copyOfRange(cue.size, conditioned.size).maxOf { abs(it) }
        assertTrue(speechPeak > 0.75f)
        assertTrue(peak(conditioned) <= 1f)
    }

    @Test
    fun `a cue marker past a very short utterance falls back to all audio`() {
        val short = tone(peak = 0.2f, count = 800)
        val conditioned = SpeechAudioConditioning.condition(short, analysisStartSample = 800)

        assertEquals(0.85f, peak(conditioned), 0.02f)
    }

    @Test
    fun `streaming conditioning uses the running peak instead of per chunk gain`() {
        val conditioned = SpeechAudioConditioning.conditionStreaming(
            tone(peak = 0.1f),
            peakSoFar = 0.2f,
        )

        assertEquals(0.425f, peak(conditioned), 0.02f)
    }
}
