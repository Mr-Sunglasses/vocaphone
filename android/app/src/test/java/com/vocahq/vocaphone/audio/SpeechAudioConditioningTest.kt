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

    @Test
    fun `a click does not set the level`() {
        // The thump of the finger tapping Stop used to set the gain for the
        // whole dictation: one sample at 0.9 and quiet speech stayed quiet.
        val recording = tone(peak = 0.05f, count = 48_000)
        for (index in 30_000 until 30_160) recording[index] = if (index % 2 == 0) 0.9f else -0.9f
        val conditioned = SpeechAudioConditioning.condition(recording)
        assertEquals(0.4f, peak(conditioned.copyOfRange(0, 29_000)), 0.02f)
    }

    @Test
    fun `nothing amplified passes full scale`() {
        // 0.85 / 0.15 is inside the gain ceiling, so the speech reaches target.
        val recording = tone(peak = 0.15f, count = 48_000)
        for (index in 30_000 until 30_160) recording[index] = 0.9f
        val conditioned = SpeechAudioConditioning.condition(recording)
        assertTrue(peak(conditioned) <= 1f)
        assertEquals(0.85f, peak(conditioned.copyOfRange(0, 29_000)), 0.02f)
    }

    @Test
    fun `silence with a click stays silent`() {
        val recording = FloatArray(48_000)
        for (index in 30_000 until 30_160) recording[index] = 0.5f
        assertTrue(peak(SpeechAudioConditioning.condition(recording)) <= 0.51f)
    }

    @Test
    fun `the limiter is continuous and bounded`() {
        assertEquals(0.5f, SpeechAudioConditioning.limited(0.5f), 0f)
        assertEquals(0.85f, SpeechAudioConditioning.limited(0.85f), 0f)
        assertTrue(SpeechAudioConditioning.limited(0.86f) > 0.85f)
        assertTrue(SpeechAudioConditioning.limited(4f) <= 1f)
        assertTrue(SpeechAudioConditioning.limited(-4f) >= -1f)
    }

    @Test
    fun `a louder streaming chunk is limited`() {
        val chunk = tone(peak = 0.5f, count = 3_200)
        assertTrue(peak(SpeechAudioConditioning.conditionStreaming(chunk, 0.1f)) <= 1f)
    }

    @Test
    fun `brief speech in a long recording still sets the level`() {
        // Three seconds of quiet speech and then five minutes of a recorder
        // left running: the silence must not push the speech out of the level.
        val recording = tone(peak = 0.05f, count = 3 * 16_000) + FloatArray(300 * 16_000)
        val conditioned = SpeechAudioConditioning.condition(recording)
        assertEquals(0.4f, peak(conditioned.copyOfRange(0, 3 * 16_000)), 0.02f)
    }

    @Test
    fun `the set aside follows the audible audio`() {
        assertEquals(2, SpeechAudioConditioning.setAside(0))
        assertEquals(25, SpeechAudioConditioning.setAside(500))
    }

    @Test
    fun `a longer knock in a dictation does not set the level`() {
        // A 300 ms fumble in ten seconds of speech.
        val recording = tone(peak = 0.05f, count = 10 * 16_000)
        for (index in 100_000 until 104_800) recording[index] = if (index % 2 == 0) 0.9f else -0.9f
        val conditioned = SpeechAudioConditioning.condition(recording)
        assertEquals(0.4f, peak(conditioned.copyOfRange(0, 99_000)), 0.02f)
    }
}
