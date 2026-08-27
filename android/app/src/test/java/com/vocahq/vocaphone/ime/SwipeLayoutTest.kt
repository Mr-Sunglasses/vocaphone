package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SwipeLayoutTest {

    @Test
    fun `qwerty neighbours match the previous layout`() {
        val g = SwipeLayout.nearby('g')
        assertTrue(g.contains('f'))
        assertTrue(g.contains('h'))
        assertTrue(g.contains('t'))
        assertFalse(g.contains('q'))
        assertFalse(g.contains('g'))
    }

    @Test
    fun `a grid point on a key centre is that key`() {
        val h = SwipeLayout.qwerty('h')!!
        val mapped = SwipeLayout.gridPoint('h', 0f, 0f)!!
        assertEquals(h.x, mapped.x, 0.001f)
        assertEquals(h.y, mapped.y, 0.001f)
    }

    @Test
    fun `interpolating a word visits its letters in order`() {
        val path = SwipeLayout.interpolate("hello")
        assertTrue(path.size >= 8)
        assertTrue(SwipeLayout.lettersLieOnPath("helo", SwipeLayout.samplePoints(path)))
        assertFalse(SwipeLayout.lettersLieOnPath("world", SwipeLayout.samplePoints(path)))
    }

    @Test
    fun `double letters are detected so a loop path can be scored`() {
        assertTrue(SwipeLayout.hasDoubleLetter("hello"))
        assertTrue(SwipeLayout.hasDoubleLetter("good"))
        assertFalse(SwipeLayout.hasDoubleLetter("world"))
    }

    @Test
    fun `a resampled path has a fixed number of points`() {
        val samples = SwipeLayout.sampleWord("hello")
        assertEquals(SwipeLayout.SAMPLE_POINTS * 2, samples.size)
    }

    @Test
    fun `a tap that stays on one key is not a swipe`() {
        assertFalse(SwipeLayout.enteredAnotherLetter("character-h", "character-h"))
        assertFalse(SwipeLayout.enteredAnotherLetter("character-h", null))
    }

    @Test
    fun `entering a different letter key starts a swipe`() {
        assertTrue(SwipeLayout.enteredAnotherLetter("character-h", "character-j"))
    }

    @Test
    fun `simplifying a what-shaped path keeps the four turns`() {
        val waypoints = SwipeLayout.simplify(SwipeLayout.interpolate("what"))
        assertEquals(4, waypoints.size)
        val keys = waypoints.map { point ->
            SwipeLayout.QWERTY.minBy { it.value.distanceTo(point) }.key
        }
        assertEquals(listOf('w', 'h', 'a', 't'), keys)
    }

    @Test
    fun `a four-apex what covers what and not wednesday`() {
        val masks = SwipeLayout.apexMasks(SwipeLayout.simplify(SwipeLayout.interpolate("what")))
        assertTrue(SwipeLayout.coversApexes("what", masks))
        assertFalse(SwipeLayout.coversApexes("wednesday", masks))
        assertFalse(SwipeLayout.coversApexes("without", masks))
        assertFalse(SwipeLayout.coversApexes("want", masks))
    }

    @Test
    fun `a straight flick only keeps the two ends`() {
        val waypoints = SwipeLayout.simplify(SwipeLayout.interpolate("wh"))
        assertEquals(2, waypoints.size)
    }
}
