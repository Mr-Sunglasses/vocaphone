package com.vocahq.vocaphone.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.VibrationEffect
import android.os.VibratorManager
import android.view.HapticFeedbackConstants
import android.view.View
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.DictationTone
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Plays the shipped start/stop WAV for a tone. Off has no file and is silent.
 * Haptics are separate: they fire even when the tone is Off.
 */
class DictationTonePlayer(context: Context) {
    private val appContext = context.applicationContext
    private val gate = Mutex()

    fun haptic() {
        val vibrator = appContext.getSystemService(VibratorManager::class.java)?.defaultVibrator
        if (vibrator != null && vibrator.hasVibrator()) {
            vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK))
            return
        }
        View(appContext).performHapticFeedback(HapticFeedbackConstants.CONFIRM)
    }

    suspend fun playStart(tone: DictationTone) = play(tone.startRes())

    suspend fun playStop(tone: DictationTone) = play(tone.stopRes())

    /** Start cue, then stop cue. Off stays silent. */
    suspend fun preview(tone: DictationTone) {
        playStart(tone)
        playStop(tone)
    }

    private suspend fun play(resId: Int?) {
        if (resId == null) return
        gate.withLock {
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val player = try {
                MediaPlayer.create(appContext, resId, attributes, 0)
            } catch (_: Throwable) {
                return@withLock
            } ?: return@withLock
            try {
                player.start()
                delay(player.duration.toLong().coerceAtLeast(0) + 24)
            } catch (_: Throwable) {
                // A missed cue must never fail a dictation.
            } finally {
                player.release()
            }
        }
    }
}

private fun DictationTone.startRes(): Int? = when (this) {
    DictationTone.LIFT -> R.raw.dictation_tone_lift_start
    DictationTone.FLICK -> R.raw.dictation_tone_flick_start
    DictationTone.EMBER -> R.raw.dictation_tone_ember_start
    DictationTone.STEP -> R.raw.dictation_tone_step_start
    DictationTone.VOCA -> R.raw.dictation_tone_voca_start
    DictationTone.SOFT -> R.raw.dictation_tone_soft_start
    DictationTone.CHIRP -> R.raw.dictation_tone_chirp_start
    DictationTone.SCALE -> R.raw.dictation_tone_scale_start
    DictationTone.DROP -> R.raw.dictation_tone_drop_start
    DictationTone.GLASS -> R.raw.dictation_tone_glass_start
    DictationTone.OFF -> null
}

private fun DictationTone.stopRes(): Int? = when (this) {
    DictationTone.LIFT -> R.raw.dictation_tone_lift_stop
    DictationTone.FLICK -> R.raw.dictation_tone_flick_stop
    DictationTone.EMBER -> R.raw.dictation_tone_ember_stop
    DictationTone.STEP -> R.raw.dictation_tone_step_stop
    DictationTone.VOCA -> R.raw.dictation_tone_voca_stop
    DictationTone.SOFT -> R.raw.dictation_tone_soft_stop
    DictationTone.CHIRP -> R.raw.dictation_tone_chirp_stop
    DictationTone.SCALE -> R.raw.dictation_tone_scale_stop
    DictationTone.DROP -> R.raw.dictation_tone_drop_stop
    DictationTone.GLASS -> R.raw.dictation_tone_glass_stop
    DictationTone.OFF -> null
}
