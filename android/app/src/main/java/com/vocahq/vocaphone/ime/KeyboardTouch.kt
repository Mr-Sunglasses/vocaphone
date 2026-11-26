package com.vocahq.vocaphone.ime

import android.media.AudioManager
import android.os.SystemClock

/**
 * When the keys were last touched, for [StripDeadZone]. Written by one
 * observer on the key area (not per key) and read when the strip is tapped.
 */
internal class KeyTouchClock {
    @Volatile
    var lastDownMs: Long = Long.MIN_VALUE / 2
        private set

    @Volatile
    var pointersDown: Int = 0
        private set

    /** A pointer event on the keys: [newDown] when a finger just touched, [pressed] fingers down now. */
    fun observe(newDown: Boolean, pressed: Int, nowMs: Long = SystemClock.uptimeMillis()) {
        if (newDown) lastDownMs = nowMs
        pointersDown = pressed
    }
}

/**
 * The lower half of the suggestion strip, just after a key press, belongs to
 * the top row. Nobody reads a new suggestion and taps it within a quarter of a
 * second of the last key; a tap there is an "e" aimed high, and picking the
 * word under it would replace what they are typing.
 */
internal object StripDeadZone {
    const val WINDOW_MS = 250L

    /** A tap at [yFraction] of the strip's height (0 top, 1 bottom) types a key instead. */
    fun typesKey(nowMs: Long, lastKeyDownMs: Long, keysDown: Int, yFraction: Float): Boolean =
        yFraction >= 0.5f && (keysDown > 0 || nowMs - lastKeyDownMs in 0..WINDOW_MS)

    /** A letter key and its horizontal extent, top edge, in root pixels. */
    data class KeySpan<K>(val key: K, val left: Float, val right: Float, val top: Float)

    /**
     * The top-row letter under [x], or the nearest one to it. The top row is
     * the letter keys with the smallest top edge, so a number row above the
     * letters is not mistaken for it.
     */
    fun <K> topRowKey(x: Float, keys: List<KeySpan<K>>): K? {
        if (keys.isEmpty()) return null
        val top = keys.minOf { it.top }
        val row = keys.filter { it.top - top < 1f }
        row.firstOrNull { x >= it.left && x < it.right }?.let { return it.key }
        return row.minByOrNull { kotlin.math.abs((it.left + it.right) / 2f - x) }?.key
    }
}

/** "Sound on keypress": the system's own key clicks. */
internal object KeyClick {
    fun effectFor(type: KeyboardKeyType): Int = when (type) {
        KeyboardKeyType.DELETE -> AudioManager.FX_KEYPRESS_DELETE
        KeyboardKeyType.SPACE -> AudioManager.FX_KEYPRESS_SPACEBAR
        KeyboardKeyType.RETURN -> AudioManager.FX_KEYPRESS_RETURN
        else -> AudioManager.FX_KEYPRESS_STANDARD
    }
}

/**
 * Key-down feedback the keys share: one object for the life of the keyboard,
 * so turning the sound on does not recompose forty keys. [play] is a one-way
 * call into the audio service; nothing is loaded on the press.
 *
 * The switches here are read by the gestures when a finger moves, never
 * during composition, so flipping one in Settings does not restart forty
 * `pointerInput` blocks.
 */
internal class KeyFeedback(private val audio: AudioManager?) {
    @Volatile
    var soundOn: Boolean = false

    /** "Haptic feedback on keypress". On, the system `KEYBOARD_TAP` (which follows the system's own switch). */
    @Volatile
    var hapticsOn: Boolean = true

    /** "Space-bar cursor control": a held space bar becomes a trackpad. */
    @Volatile
    var spaceCursorOn: Boolean = true

    fun play(type: KeyboardKeyType) {
        if (!soundOn) return
        runCatching { audio?.playSoundEffect(KeyClick.effectFor(type), -1f) }
    }
}
