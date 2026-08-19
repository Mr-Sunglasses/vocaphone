package com.vocahq.vocaphone.ime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorSelectionSyncTest {

    @Test
    fun aCollapsedCursorNeedsNoRead() {
        assertFalse(EditorSelectionSync.mustReadSelection(selStart = 0, selEnd = 0))
        assertFalse(EditorSelectionSync.mustReadSelection(selStart = 12, selEnd = 12))
    }

    @Test
    fun aRealSelectionIsRead() {
        assertTrue(EditorSelectionSync.mustReadSelection(selStart = 4, selEnd = 9))
    }

    /** Some editors report the end first; either order is still a selection. */
    @Test
    fun reversedBoundsAreStillASelection() {
        assertTrue(EditorSelectionSync.mustReadSelection(selStart = 9, selEnd = 4))
    }

    /**
     * Before the first onUpdateSelection there is nothing to reason from, and
     * guessing "empty" would silently disable case-cycling on a field opened
     * with text already selected.
     */
    @Test
    fun boundsNoEditorHasReportedYetAreRead() {
        assertTrue(EditorSelectionSync.mustReadSelection(selStart = -1, selEnd = -1))
        assertTrue(EditorSelectionSync.mustReadSelection(selStart = -1, selEnd = 0))
        assertTrue(EditorSelectionSync.mustReadSelection(selStart = 0, selEnd = -1))
    }
}
