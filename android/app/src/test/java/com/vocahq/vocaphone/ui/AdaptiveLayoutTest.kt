package com.vocahq.vocaphone.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AdaptiveLayoutTest {

    @Test
    fun `phone action pairs stack when their content area is narrow`() {
        assertTrue(AdaptiveLayout.stackActions(widthDp = 320f, fontScale = 1f))
        assertFalse(AdaptiveLayout.stackActions(widthDp = 379f, fontScale = 1f))
    }

    @Test
    fun `large text folds action pairs before labels are squeezed`() {
        assertTrue(AdaptiveLayout.stackActions(widthDp = 379f, fontScale = 1.2f))
        assertFalse(AdaptiveLayout.stackActions(widthDp = 720f, fontScale = 1.5f))
    }

    @Test
    fun `pixel width model content uses one readable column`() {
        // Pixel 6a is about 411 dp wide; page padding leaves about 379 dp.
        assertEquals(1, AdaptiveLayout.modelGridColumns(widthDp = 379f, fontScale = 1f))
        assertEquals(2, AdaptiveLayout.modelGridColumns(widthDp = 411f, fontScale = 1f))
    }

    @Test
    fun `model grid responds to accessibility text and wide screens`() {
        assertEquals(1, AdaptiveLayout.modelGridColumns(widthDp = 500f, fontScale = 1.5f))
        assertEquals(2, AdaptiveLayout.modelGridColumns(widthDp = 720f, fontScale = 1.5f))
    }

    @Test
    fun `long checklist actions stack in inset cards on a pixel`() {
        assertTrue(AdaptiveLayout.stackChecklistAction(widthDp = 347f, fontScale = 1f))
        assertFalse(AdaptiveLayout.stackChecklistAction(widthDp = 480f, fontScale = 1f))
    }

    @Test
    fun `diagnostic rows stack only when values lose useful width`() {
        assertTrue(AdaptiveLayout.stackInfo(widthDp = 300f, fontScale = 1f))
        assertFalse(AdaptiveLayout.stackInfo(widthDp = 379f, fontScale = 1f))
        assertTrue(AdaptiveLayout.stackInfo(widthDp = 379f, fontScale = 1.3f))
    }
}
