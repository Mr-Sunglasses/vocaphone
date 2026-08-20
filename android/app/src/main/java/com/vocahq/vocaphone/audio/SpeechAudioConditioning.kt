package com.vocahq.vocaphone.audio

import kotlin.math.abs

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

        var peak = 0f
        for (index in analysisStart until samples.size) {
            val magnitude = abs(samples[index])
            if (magnitude > peak) peak = magnitude
        }
        if (peak < SILENCE_PEAK) return samples

        // Already loud enough. Attenuating a hot recording cannot undo whatever
        // clipping it arrived with, and quiet is the problem worth solving.
        val gain = gainFor(peak)
        if (gain <= 1f) return samples

        for (index in samples.indices) {
            samples[index] = (samples[index] * gain).coerceIn(-1f, 1f)
        }
        return samples
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

        for (index in samples.indices) samples[index] *= gain
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

    /** One AudioRecord frame: enough signal to derive a meaningful level. */
    private const val MIN_ANALYSIS_SAMPLES = CaptureFormat.SAMPLE_RATE / 10
}
