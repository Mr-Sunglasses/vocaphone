package com.vocahq.vocaphone.audio

import com.vocahq.vocaphone.core.DictationTone

/**
 * Preview is a fake dictation session: start cue, then stop cue.
 * It never opens the microphone or starts [android.media.AudioRecord].
 */
object TonePreview {
    const val OPENS_MICROPHONE = false

    fun nextListening(currentlyListening: Boolean, tone: DictationTone): Boolean {
        if (!tone.playsCues) return false
        return !currentlyListening
    }
}
