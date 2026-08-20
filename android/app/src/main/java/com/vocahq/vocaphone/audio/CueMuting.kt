package com.vocahq.vocaphone.audio

/**
 * Keeps the opening cue out of the recording without eating the opening of the
 * sentence.
 *
 * The microphone is opened while the cue is still sounding, so that the cue
 * plays over `AudioRecord`'s warm-up instead of in front of it, and the frames
 * that overlap the cue are discarded rather than transcribed. That much is
 * sound. What is not is telling the user the keyboard is listening while those
 * frames are still going in the bin: anyone who starts talking on the cue --
 * which is what a cue is for -- loses however much of it the cue still had left
 * to run, up to 600 ms with the Lift tone.
 *
 * Losing it costs more than the words. The offline sherpa-onnx models are fed a
 * whole utterance at a time, and a clip that begins part-way through the first
 * syllable gives their decoder a bad first token to build the rest of the
 * hypothesis on. A dictation that was merely missing a word came back with a
 * worse version of everything after it too.
 *
 * So the wait comes back, minus the part of it the warm-up already paid for,
 * and the user is told to speak only once what they say is being kept.
 */
internal object CueMuting {

    /**
     * How long to hold off announcing that the keyboard is listening.
     *
     * Zero once the cue has fallen quiet, which is the common case by the time
     * the recorder has finished opening, and always zero for the Off tone.
     */
    fun waitMillis(cueQuietAtMillis: Long, nowMillis: Long): Long =
        (cueQuietAtMillis - nowMillis).coerceAtLeast(0L)

    /** Whether a frame captured at [frameAtMillis] is voice rather than cue. */
    fun keepsFrame(frameAtMillis: Long, cueQuietAtMillis: Long): Boolean =
        frameAtMillis >= cueQuietAtMillis
}
