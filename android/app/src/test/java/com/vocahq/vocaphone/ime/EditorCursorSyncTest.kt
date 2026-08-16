package com.vocahq.vocaphone.ime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorCursorSyncTest {

    @Test
    fun composingGrowthIsNotAUserMove() {
        assertFalse(
            EditorCursorSync.isUserMove(
                oldSelStart = 10,
                oldSelEnd = 10,
                newSelStart = 11,
                newSelEnd = 11,
                oldCandidatesStart = -1,
                oldCandidatesEnd = -1,
                newCandidatesStart = 10,
                newCandidatesEnd = 11,
            ),
        )
        assertFalse(
            EditorCursorSync.isUserMove(
                oldSelStart = 11,
                oldSelEnd = 11,
                newSelStart = 12,
                newSelEnd = 12,
                oldCandidatesStart = 10,
                oldCandidatesEnd = 11,
                newCandidatesStart = 10,
                newCandidatesEnd = 12,
            ),
        )
    }

    @Test
    fun composingBackspaceIsNotAUserMove() {
        assertFalse(
            EditorCursorSync.isUserMove(
                oldSelStart = 12,
                oldSelEnd = 12,
                newSelStart = 11,
                newSelEnd = 11,
                oldCandidatesStart = 10,
                oldCandidatesEnd = 12,
                newCandidatesStart = 10,
                newCandidatesEnd = 11,
            ),
        )
    }

    @Test
    fun finishingAWordInPlaceIsNotAUserMove() {
        assertFalse(
            EditorCursorSync.isUserMove(
                oldSelStart = 15,
                oldSelEnd = 15,
                newSelStart = 16,
                newSelEnd = 16,
                oldCandidatesStart = 10,
                oldCandidatesEnd = 15,
                newCandidatesStart = -1,
                newCandidatesEnd = -1,
            ),
        )
    }

    @Test
    fun tappingAwayFromComposingIsAUserMove() {
        assertTrue(
            EditorCursorSync.isUserMove(
                oldSelStart = 15,
                oldSelEnd = 15,
                newSelStart = 3,
                newSelEnd = 3,
                oldCandidatesStart = 10,
                oldCandidatesEnd = 15,
                newCandidatesStart = -1,
                newCandidatesEnd = -1,
            ),
        )
    }

    @Test
    fun tappingInsideComposingIsAUserMove() {
        assertTrue(
            EditorCursorSync.isUserMove(
                oldSelStart = 15,
                oldSelEnd = 15,
                newSelStart = 12,
                newSelEnd = 12,
                oldCandidatesStart = 10,
                oldCandidatesEnd = 15,
                newCandidatesStart = 10,
                newCandidatesEnd = 15,
            ),
        )
    }

    @Test
    fun selectingTextIsAUserMove() {
        assertTrue(
            EditorCursorSync.isUserMove(
                oldSelStart = 15,
                oldSelEnd = 15,
                newSelStart = 4,
                newSelEnd = 9,
                oldCandidatesStart = -1,
                oldCandidatesEnd = -1,
                newCandidatesStart = -1,
                newCandidatesEnd = -1,
            ),
        )
    }

    @Test
    fun anUnchangedSelectionIsNotAUserMove() {
        assertFalse(
            EditorCursorSync.isUserMove(
                oldSelStart = 8,
                oldSelEnd = 8,
                newSelStart = 8,
                newSelEnd = 8,
                oldCandidatesStart = -1,
                oldCandidatesEnd = -1,
                newCandidatesStart = -1,
                newCandidatesEnd = -1,
            ),
        )
    }
}
