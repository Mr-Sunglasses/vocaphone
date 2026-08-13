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
     * loudest sample in what it is given, so feeding it one streaming chunk at
     * a time would apply a different gain to each — jarring across a chunk
     * boundary, and outright wrong for a chunk that happens to be a pause.
     */
    fun condition(samples: FloatArray): FloatArray {
        if (samples.isEmpty()) return samples

        // A DC offset costs a model headroom and shifts every frame's energy
        // without carrying any of the speech. Some phone inputs have a real one.
        var sum = 0.0
        for (sample in samples) sum += sample
        val offset = (sum / samples.size).toFloat()
        if (abs(offset) > 1e-4f) {
            for (index in samples.indices) samples[index] -= offset
        }

        var peak = 0f
        for (sample in samples) {
            val magnitude = abs(sample)
            if (magnitude > peak) peak = magnitude
        }
        if (peak < SILENCE_PEAK) return samples

        // Already loud enough. Attenuating a hot recording cannot undo whatever
        // clipping it arrived with, and quiet is the problem worth solving.
        val gain = (TARGET_PEAK / peak).coerceAtMost(MAX_GAIN)
        if (gain <= 1f) return samples

        for (index in samples.indices) samples[index] *= gain
        return samples
    }
}
