package com.vocahq.vocaphone.core

import kotlin.math.max

/**
 * Decides when a dictation has ended because the speaker stopped talking.
 *
 * Opt-in, because people pause to think in the middle of a sentence and a
 * recording that stops under them is worse than one they have to stop.
 * Deliberately hard to trigger: nothing counts until a full second of speech
 * has been heard, and only an unbroken stretch of quiet after it ends the
 * recording. "Quiet" is judged against the room's own floor, tracked from the
 * levels themselves, so a fan does not read as speech forever and a silent
 * room does not read as a pause the moment breath is drawn.
 *
 * Works on RMS amplitude (0..1). Mirrors `PauseDetector.swift`.
 */
class PauseDetector {
    var floor = 0f
        private set
    var speechSeconds = 0.0
        private set
    var quietSeconds = 0.0
        private set

    /** Feeds one level lasting [seconds]; true once the recording should finish. */
    fun observe(rms: Float, seconds: Double): Boolean {
        val level = max(0f, rms)
        // The floor follows the quietest level down at once and creeps up over
        // about a minute, so a minute of talking barely moves it. A room that
        // gets louder mid-recording is read as speech until the floor catches
        // up — which errs towards not stopping, the safe side.
        if (floor == 0f || level < floor) {
            floor = level
        } else {
            floor += (level - floor) * seconds.toFloat() * 0.02f
        }
        if (level >= max(floor * SPEECH_OVER_FLOOR, MINIMUM_SPEECH_LEVEL)) {
            speechSeconds += seconds
            quietSeconds = 0.0
        } else if (speechSeconds >= MINIMUM_SPEECH_SECONDS) {
            quietSeconds += seconds
        }
        return speechSeconds >= MINIMUM_SPEECH_SECONDS && quietSeconds >= PAUSE_SECONDS
    }

    companion object {
        /** How long the quiet has to last. */
        const val PAUSE_SECONDS = 3.0
        /** How much speech has to come first. */
        const val MINIMUM_SPEECH_SECONDS = 1.0
        /** Speech is this many times the floor, and never below about −42 dBFS. */
        const val SPEECH_OVER_FLOOR = 4f
        const val MINIMUM_SPEECH_LEVEL = 0.008f
    }
}
