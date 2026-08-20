package com.vocahq.vocaphone.audio

/** Coordinates the audible start cue with the listening state and haptic. */
internal object CueTiming {

    /**
     * How long to hold off announcing that the keyboard is listening.
     *
     * This delay never gates captured audio. Every frame AudioRecord produces
     * is retained, including speech that begins while the tone is sounding.
     * The cue is a user-facing readiness signal, not permission to delete the
     * microphone underneath it.
     */
    fun waitMillis(cueQuietAtMillis: Long, nowMillis: Long): Long =
        (cueQuietAtMillis - nowMillis).coerceAtLeast(0L)

    /**
     * First sample suitable for measuring speech level.
     *
     * A frame is timestamped when AudioRecord returns it, so the first frame
     * after the cue deadline can still contain the end of the tone. Skip that
     * one frame for level measurement as well. The samples remain in the model
     * input; this prevents the cue's peak from making quiet speech look quieter.
     */
    fun conditioningStartSample(
        cueOverlapSamples: Int,
        frameSamples: Int,
        cuePlayed: Boolean,
    ): Int = if (cuePlayed) {
        cueOverlapSamples.coerceAtLeast(0) + frameSamples.coerceAtLeast(0)
    } else {
        0
    }
}
