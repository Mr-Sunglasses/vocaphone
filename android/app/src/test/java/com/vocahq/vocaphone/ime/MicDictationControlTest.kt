package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.DictationPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MicDictationControlTest {

    @Test
    fun `tap starts or finishes by phase`() {
        assertEquals(MicDictationAction.START, MicDictationControl.tap(DictationPhase.IDLE))
        assertEquals(MicDictationAction.FINISH, MicDictationControl.tap(DictationPhase.LISTENING))
        // A failure or a saved transcript is not in the way of a new take.
        assertEquals(MicDictationAction.START, MicDictationControl.tap(DictationPhase.FAILED))
        assertEquals(MicDictationAction.START, MicDictationControl.tap(DictationPhase.READY_TO_INSERT))
    }

    @Test
    fun `a tap on the processing spinner never discards the dictation`() {
        // It used to cancel and delete the recording; discarding is the X.
        for (phase in listOf(
            DictationPhase.FINALIZING,
            DictationPhase.UPLOADING,
            DictationPhase.TRANSCRIBING,
            DictationPhase.INSERTING,
        )) {
            assertEquals(phase.name, MicDictationAction.NONE, MicDictationControl.tap(phase))
        }
    }

    @Test
    fun `a tap on a repair checks again instead of always opening the app`() {
        assertEquals(
            MicDictationAction.RECHECK_SETUP,
            MicDictationControl.tap(DictationPhase.PERMISSION_REPAIR),
        )
    }

    @Test
    fun `long press cancels only while dictation owns the mic or the pipeline`() {
        assertEquals(
            MicDictationAction.CANCEL,
            MicDictationControl.longPress(DictationPhase.LISTENING),
        )
        assertEquals(
            MicDictationAction.CANCEL,
            MicDictationControl.longPress(DictationPhase.TRANSCRIBING),
        )
        assertNull(MicDictationControl.longPress(DictationPhase.IDLE))
        assertNull(MicDictationControl.longPress(DictationPhase.FAILED))
    }

    @Test
    fun `separate cancel shows whenever dictation is running, listening included`() {
        assertFalse(MicDictationControl.showsSeparateCancel(DictationPhase.IDLE))
        assertTrue(MicDictationControl.showsSeparateCancel(DictationPhase.LISTENING))
        assertTrue(MicDictationControl.showsSeparateCancel(DictationPhase.UPLOADING))
        assertTrue(MicDictationControl.showsSeparateCancel(DictationPhase.TRANSCRIBING))
        assertTrue(MicDictationControl.showsSeparateCancel(DictationPhase.FINALIZING))
        assertTrue(MicDictationControl.showsSeparateCancel(DictationPhase.INSERTING))
        assertFalse(MicDictationControl.showsSeparateCancel(DictationPhase.FAILED))
        assertFalse(MicDictationControl.showsSeparateCancel(DictationPhase.INSERTED))
        assertFalse(MicDictationControl.showsSeparateCancel(DictationPhase.PERMISSION_REPAIR))
    }

    @Test
    fun `a failed empty transcript does not lock the keyboard menu`() {
        assertTrue(MicDictationControl.allowsMenu(DictationPhase.IDLE))
        assertTrue(MicDictationControl.allowsMenu(DictationPhase.FAILED))
        assertTrue(MicDictationControl.allowsMenu(DictationPhase.INSERTED))
        assertFalse(MicDictationControl.allowsMenu(DictationPhase.LISTENING))
        assertFalse(MicDictationControl.allowsMenu(DictationPhase.TRANSCRIBING))
    }
}
