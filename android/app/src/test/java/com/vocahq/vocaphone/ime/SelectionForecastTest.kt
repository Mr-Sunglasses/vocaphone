package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SelectionForecastTest {

    @Test
    fun `letters committed one by one on a layout that does not compose are not taps`() {
        val forecast = SelectionForecast()
        forecast.reset(5, 5)
        // "при" on the Russian layout: three commitText calls, no composing region.
        repeat(3) { forecast.commit(1) }
        assertTrue(forecast.onUpdate(6, 6, -1))
        assertTrue(forecast.onUpdate(7, 7, -1))
        assertTrue(forecast.onUpdate(8, 8, -1))
        // Then a tap somewhere else is still a tap.
        assertFalse(forecast.onUpdate(2, 2, -1))
    }

    @Test
    fun `an editor that coalesces updates matches the last edit`() {
        val forecast = SelectionForecast()
        forecast.reset(0, 0)
        repeat(4) { forecast.commit(1) }
        assertTrue(forecast.onUpdate(4, 4, -1))
        // Nothing left pending: a later update where the cursor already was is not ours.
        assertFalse(forecast.onUpdate(3, 3, -1))
    }

    @Test
    fun `the punctuation swap after a layer switch is the keyboard's own edit`() {
        val forecast = SelectionForecast()
        forecast.reset(0, 0)
        // "teh" composing, finished by ?123, then "?" puts the held fix in place.
        forecast.compose(1); forecast.compose(2); forecast.compose(3)
        forecast.finishComposing()
        forecast.commit("the".length, deleteBefore = "teh".length)
        forecast.commit(1)
        assertTrue(forecast.onUpdate(1, 1, 0))
        assertTrue(forecast.onUpdate(2, 2, 0))
        assertTrue(forecast.onUpdate(3, 3, 0))
        assertTrue(forecast.onUpdate(3, 3, -1))
        assertTrue(forecast.onUpdate(3, 3, -1))
        assertTrue(forecast.onUpdate(4, 4, -1))
    }

    @Test
    fun `space after a composed word and a period is not a tap`() {
        val forecast = SelectionForecast()
        forecast.reset(10, 10)
        // "etc" composing, then "." and " " committed.
        forecast.compose(1); forecast.compose(2); forecast.compose(3)
        forecast.commit(1)
        forecast.commit(1)
        assertTrue(forecast.onUpdate(11, 11, 10))
        assertTrue(forecast.onUpdate(12, 12, 10))
        assertTrue(forecast.onUpdate(13, 13, 10))
        assertTrue(forecast.onUpdate(14, 14, -1))
        assertTrue(forecast.onUpdate(15, 15, -1))
        assertEquals(15, forecast.cursor)
    }

    @Test
    fun `double space period lands one past the space`() {
        val forecast = SelectionForecast()
        forecast.reset(3, 3)
        forecast.commit(1)
        forecast.commit(2, deleteBefore = 1)
        assertTrue(forecast.onUpdate(4, 4, -1))
        assertTrue(forecast.onUpdate(5, 5, -1))
    }

    @Test
    fun `an edit it cannot work out leaves the editor to decide, then re-anchors`() {
        val forecast = SelectionForecast()
        forecast.reset(5, 5)
        forecast.forget()
        forecast.commit(1)
        assertEquals(-1, forecast.cursor)
        // Nothing was forecast, so the delete's update is believed and anchors the next key.
        assertFalse(forecast.onUpdate(4, 4, -1))
        forecast.commit(1)
        assertTrue(forecast.onUpdate(5, 5, -1))
    }

    @Test
    fun `a selection is never forecast`() {
        val forecast = SelectionForecast()
        forecast.reset(2, 6)
        forecast.commit(1)
        assertFalse(forecast.onUpdate(3, 3, -1))
    }

    @Test
    fun `an editor that never reports does not leave stale matches behind`() {
        val forecast = SelectionForecast()
        forecast.reset(0, 0)
        repeat(40) { forecast.commit(1) }
        assertFalse(forecast.onUpdate(5, 5, -1))
    }
}
