package com.vocahq.vocaphone.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class HistorySelectionTest {

    @Test
    fun tapTogglesMembershipAndDeselectingTheLastItemClearsTheSet() {
        val one = toggleHistorySelection(emptySet(), "a")
        assertEquals(setOf("a"), one)
        val two = toggleHistorySelection(one, "b")
        assertEquals(setOf("a", "b"), two)
        assertEquals(setOf("b"), toggleHistorySelection(two, "a"))
        assertEquals(emptySet<String>(), toggleHistorySelection(setOf("b"), "b"))
    }

    @Test
    fun selectionBarTitleNamesTheModeBeforeAnythingIsChecked() {
        assertEquals("Select items", historySelectionTitle(0))
        assertEquals("1 selected", historySelectionTitle(1))
        assertEquals("3 selected", historySelectionTitle(3))
    }
}
