package com.vocahq.vocaphone.ime

import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardTouchTest {
    private val topRow = "qwertyuiop".mapIndexed { index, letter ->
        StripDeadZone.KeySpan(letter, left = index * 40f, right = index * 40f + 36f, top = 200f)
    }
    private val homeRow = "asdfghjkl".mapIndexed { index, letter ->
        StripDeadZone.KeySpan(letter, left = 20f + index * 40f, right = 56f + index * 40f, top = 250f)
    }

    @Test
    fun `a low tap just after a key types a key`() {
        assertTrue(StripDeadZone.typesKey(nowMs = 1_100, lastKeyDownMs = 1_000, keysDown = 0, yFraction = 0.7f))
        assertTrue(StripDeadZone.typesKey(nowMs = 1_250, lastKeyDownMs = 1_000, keysDown = 0, yFraction = 0.5f))
    }

    @Test
    fun `a tap high on the strip, or a moment later, picks the suggestion`() {
        assertFalse(StripDeadZone.typesKey(nowMs = 1_100, lastKeyDownMs = 1_000, keysDown = 0, yFraction = 0.4f))
        assertFalse(StripDeadZone.typesKey(nowMs = 1_251, lastKeyDownMs = 1_000, keysDown = 0, yFraction = 0.9f))
    }

    @Test
    fun `a key still held makes the lower half a key whenever`() {
        assertTrue(StripDeadZone.typesKey(nowMs = 9_000, lastKeyDownMs = 1_000, keysDown = 1, yFraction = 0.6f))
    }

    @Test
    fun `the key is the top-row letter under the finger, or the nearest`() {
        val keys = homeRow + topRow
        assertEquals('e', StripDeadZone.topRowKey(85f, keys))
        // In the gap between w and e: nearest centre.
        assertEquals('w', StripDeadZone.topRowKey(77f, keys))
        assertEquals('p', StripDeadZone.topRowKey(900f, keys))
        assertNull(StripDeadZone.topRowKey(10f, emptyList<StripDeadZone.KeySpan<Char>>()))
    }

    @Test
    fun `the clock remembers the last touch and how many fingers are down`() {
        val clock = KeyTouchClock()
        clock.observe(newDown = true, pressed = 1, nowMs = 500)
        assertEquals(500L, clock.lastDownMs)
        assertEquals(1, clock.pointersDown)
        clock.observe(newDown = false, pressed = 0, nowMs = 600)
        assertEquals(500L, clock.lastDownMs)
        assertEquals(0, clock.pointersDown)
    }

    @Test
    fun `each key gets its own click`() {
        assertEquals(AudioManager.FX_KEYPRESS_STANDARD, KeyClick.effectFor(KeyboardKeyType.CHARACTER))
        assertEquals(AudioManager.FX_KEYPRESS_DELETE, KeyClick.effectFor(KeyboardKeyType.DELETE))
        assertEquals(AudioManager.FX_KEYPRESS_SPACEBAR, KeyClick.effectFor(KeyboardKeyType.SPACE))
        assertEquals(AudioManager.FX_KEYPRESS_RETURN, KeyClick.effectFor(KeyboardKeyType.RETURN))
        assertEquals(AudioManager.FX_KEYPRESS_STANDARD, KeyClick.effectFor(KeyboardKeyType.SHIFT))
    }

    @Test
    fun `sound off plays nothing and never touches the audio service`() {
        val feedback = KeyFeedback(audio = null)
        feedback.play(KeyboardKeyType.CHARACTER)
        feedback.soundOn = true
        feedback.play(KeyboardKeyType.CHARACTER)
    }
}
