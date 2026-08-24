package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Test

class AccentPickerTest {

    @Test
    fun `row grows right of the key when it fits`() {
        val left = AccentPicker.rowLeft(
            centerX = 200f,
            count = 4,
            cellPx = 50f,
            parentWidth = 1000f,
        )
        assertEquals(175f, left)
    }

    @Test
    fun `row shifts right when the key is against the left edge`() {
        val left = AccentPicker.rowLeft(
            centerX = 10f,
            count = 9,
            cellPx = 50f,
            parentWidth = 1080f,
        )
        assertEquals(0f, left)
    }

    @Test
    fun `row shifts left when the key is against the right edge`() {
        val left = AccentPicker.rowLeft(
            centerX = 1040f,
            count = 9,
            cellPx = 50f,
            parentWidth = 1080f,
        )
        assertEquals(1080f - 450f, left)
    }

    @Test
    fun `index follows the finger along the row`() {
        val left = 100f
        assertEquals(0, AccentPicker.indexAt(110f, left, 50f, 9))
        assertEquals(1, AccentPicker.indexAt(160f, left, 50f, 9))
        assertEquals(8, AccentPicker.indexAt(900f, left, 50f, 9))
        assertEquals(0, AccentPicker.indexAt(0f, left, 50f, 9))
    }
}
