package com.vocahq.vocaphone.audio

import kotlin.math.abs
import kotlin.math.tanh

/**
 * Levels a recording before an on-device model sees it.
 *
 * `VOICE_RECOGNITION` deliberately turns off the automatic gain control the
 * camera and voice-call paths apply, which is the right choice — AGC pumps, and
 * pumping is worse for a recognizer than a quiet signal. The cost is that a
 * phone on a desk or held at arm's length produces a waveform far below the
 * level the models were trained on, and the int8-quantized ones lose real
 * accuracy to that. One fixed gain over the whole recording recovers it without
 * introducing any of the dynamics AGC would.
 *
 * This never touches the WAV on disk or the bytes going to the gateway. It
 * applies to the copy handed to a local engine and nothing else, so a retry
 * against the gateway still sends exactly what the microphone heard.
 */
object SpeechAudioConditioning {

    /** Enough headroom that no rounding on the way into a model clips. */
    private const val TARGET_PEAK = 0.85f

    /**
     * A ceiling on the boost. Without one, a recording of a closed door becomes
     * a recording of a room's noise floor at full scale, which models
     * cheerfully transcribe as words.
     */
    private const val MAX_GAIN = 8f

    /**
     * Below this the recording is silence rather than quiet speech — most often
     * the exact zeros Android feeds an app whose microphone another app took.
     * Amplifying that would both manufacture noise and defeat the silence
     * detection that produces a message the user can act on.
     */
    private const val SILENCE_PEAK = 0.005f

    /**
     * Returns [samples] levelled in place.
     *
     * In place because the caller has just decoded a whole recording into a
     * fresh array and a second copy of five minutes of audio is worth avoiding.
     *
     * Only whole recordings should be passed here. The gain is derived from the
     * recording after [analysisStartSample], allowing a known start-cue prefix
     * to stay in the audio without setting the speech level. Feeding streaming
     * chunks here would apply a different gain to each — jarring across a chunk
     * boundary, and outright wrong for a chunk that happens to be a pause.
     */
    fun condition(samples: FloatArray, analysisStartSample: Int = 0): FloatArray {
        if (samples.isEmpty()) return samples

        val requestedStart = analysisStartSample.coerceIn(0, samples.size)
        // A very short utterance can fit entirely under a long cue. In that
        // case analysing all of it is safer than deriving a gain from no audio.
        val analysisStart = requestedStart.takeIf {
            samples.size - it >= MIN_ANALYSIS_SAMPLES
        } ?: 0

        // A DC offset costs a model headroom and shifts every frame's energy
        // without carrying any of the speech. Some phone inputs have a real one.
        var sum = 0.0
        for (index in analysisStart until samples.size) sum += samples[index]
        val offset = (sum / (samples.size - analysisStart)).toFloat()
        if (abs(offset) > 1e-4f) {
            for (index in samples.indices) samples[index] -= offset
        }

        val level = speechLevel(samples, analysisStart)
        if (level < SILENCE_PEAK) return samples

        // Already loud enough. Attenuating a hot recording cannot undo whatever
        // clipping it arrived with, and quiet is the problem worth solving.
        val gain = gainFor(level)
        if (gain <= 1f) return samples

        for (index in samples.indices) {
            samples[index] = limited(samples[index] * gain)
        }
        return samples
    }

    /**
     * The level a recording's gain is derived from: its loudest 20 ms frames,
     * with the very loudest few set aside.
     *
     * The single loudest sample used to decide it, and the loudest sample of a
     * dictation is often not speech: the thump of the finger that tapped Stop,
     * a knock on the desk, the phone being set down. One of those at 0.9 left
     * speech at 0.1 exactly where it was, when the recording otherwise earned
     * eight times the level. Setting aside the loudest 2% of frames (at least
     * two, so a click that straddles a boundary goes too) takes a transient out
     * of the decision; real speech keeps nearly all of its level, and [limited]
     * rounds off the peaks that sit above it.
     */
    fun speechLevel(samples: FloatArray, start: Int = 0): Float {
        val frameCount = (samples.size - start + FRAME_SAMPLES - 1) / FRAME_SAMPLES
        if (frameCount <= 0) return 0f
        val frames = FloatArray(frameCount)
        for (frame in 0 until frameCount) {
            val from = start + frame * FRAME_SAMPLES
            val to = minOf(from + FRAME_SAMPLES, samples.size)
            var loudest = 0f
            for (index in from until to) loudest = maxOf(loudest, abs(samples[index]))
            frames[frame] = loudest
        }
        if (frameCount <= MINIMUM_FRAMES) return frames.max()
        frames.sortDescending()
        val skipped = maxOf(2, frameCount / 50)
        return frames[minOf(skipped, frameCount - 1)]
    }

    /**
     * Leaves everything up to the target alone and bends what is above it
     * smoothly towards full scale, never past it. A transient [speechLevel] set
     * aside is amplified with the speech and would otherwise clip; so would a
     * streaming chunk louder than every one before it.
     */
    fun limited(sample: Float): Float {
        val magnitude = abs(sample)
        if (magnitude <= TARGET_PEAK) return sample
        val headroom = 1f - TARGET_PEAK
        val bent = TARGET_PEAK + headroom * tanh((magnitude - TARGET_PEAK) / headroom)
        return if (sample < 0f) -bent else bent
    }

    /**
     * Levels one streaming chunk with the loudest raw sample seen so far.
     *
     * This is only for the latency path. The complete-WAV path above stays
     * authoritative whenever the gain moves materially between chunks, because
     * a single recording-wide gain is more accurate than a sequence of gains
     * that step at chunk boundaries.
     */
    fun conditionStreaming(samples: FloatArray, peakSoFar: Float): FloatArray {
        if (samples.isEmpty()) return samples

        val gain = gainFor(peakSoFar)
        if (gain <= 1f) return samples

        for (index in samples.indices) samples[index] = limited(samples[index] * gain)
        return samples
    }

    /**
     * The gain [conditionStreaming] applies for [peak]. 1 means untouched.
     *
     * Exposed so the streaming caller can compare the gains it actually used
     * rather than the running peak they came from. That peak grows on nearly
     * every recording -- anyone who gets louder as they go moves it -- while
     * the gain it derives usually does not, and the gain is what reaches the
     * model. Treating peak growth as a level change made the latency path
     * discard its work almost every time.
     */
    fun gainFor(peak: Float): Float {
        if (peak < SILENCE_PEAK) return 1f
        return (TARGET_PEAK / peak).coerceIn(1f, MAX_GAIN)
    }

    /** 20 ms at 16 kHz: short enough that a click fills one or two frames. */
    private const val FRAME_SAMPLES = CaptureFormat.SAMPLE_RATE / 50

    /** Below this many frames nothing can be called a transient; the peak decides. */
    private const val MINIMUM_FRAMES = 10

    /** One AudioRecord frame: enough signal to derive a meaningful level. */
    private const val MIN_ANALYSIS_SAMPLES = CaptureFormat.SAMPLE_RATE / 10
}
