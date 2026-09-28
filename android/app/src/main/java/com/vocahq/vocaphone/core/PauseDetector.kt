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
    /** How loud the speech has been, a running average of speech levels. */
    var speechLevel = 0f
        private set
    var speechSeconds = 0.0
        private set
    var quietSeconds = 0.0
        private set
    private val recent = ArrayDeque<Pair<Float, Double>>()
    private var recentSeconds = 0.0

    /** Feeds one level lasting [seconds]; true once the recording should finish. */
    fun observe(rms: Float, seconds: Double): Boolean {
        val level = max(0f, rms)
        recent.addLast(level to seconds)
        recentSeconds += seconds
        while (recent.size > 1 && recentSeconds - recent.first().second >= STEADY_SECONDS) {
            recentSeconds -= recent.removeFirst().second
        }
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
            speechLevel = if (speechLevel == 0f) level else speechLevel + (level - speechLevel) * 0.1f
        } else if (speechSeconds >= MINIMUM_SPEECH_SECONDS && isQuiet(level)) {
            quietSeconds += seconds
        } else {
            // Neither speech nor a pause — a sound the floor has absorbed but
            // that is as loud as the talking was, or softer speech still moving
            // like speech. It breaks a quiet stretch.
            quietSeconds = 0.0
        }
        return speechSeconds >= MINIMUM_SPEECH_SECONDS && quietSeconds >= PAUSE_SECONDS
    }

    private fun isQuiet(level: Float): Boolean {
        if (level * CLEARLY_UNDER_SPEECH <= speechLevel) return true
        if (level * PAUSE_UNDER_SPEECH > speechLevel || recent.isEmpty()) return false
        val loudest = recent.maxOf { it.first }
        val quietest = recent.minOf { it.first }
        return loudest <= max(quietest, MINIMUM_SPEECH_LEVEL / 100) * STEADY_RANGE
    }

    companion object {
        /** How long the quiet has to last. */
        const val PAUSE_SECONDS = 3.0
        /** How much speech has to come first. */
        const val MINIMUM_SPEECH_SECONDS = 1.0
        /** Speech is this many times the floor, and never below about −42 dBFS. */
        const val SPEECH_OVER_FLOOR = 4f
        const val MINIMUM_SPEECH_LEVEL = 0.008f
        /**
         * A level this far under the speech before it — a quarter, about 12 dB
         * — is quiet whatever it does: room tone, breath, silence.
         */
        const val CLEARLY_UNDER_SPEECH = 4f
        /**
         * Between that and half the speech level, level alone cannot tell
         * steady background from someone carrying on more softly. Movement can:
         * speech rises and falls with every syllable, a fan or traffic holds its
         * level. So in that band a level is quiet only if the recent ones held
         * steady, the loudest within [STEADY_RANGE] of the quietest.
         *
         * A fan that switches on mid-recording is heard as speech until the
         * floor catches up with it, and in that time it pulls the speech level
         * down to its own; afterwards it is never under half of it, so it never
         * reads as the pause.
         */
        const val PAUSE_UNDER_SPEECH = 2f
        const val STEADY_RANGE = 2f
        /**
         * How much recent audio steadiness is judged over: a few syllables. The
         * pause clock starts once this much steady background has been heard.
         */
        const val STEADY_SECONDS = 0.6
    }
}
