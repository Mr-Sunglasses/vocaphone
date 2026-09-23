package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MicDictationControlTest {

    @Test
    fun `tap starts, finishes, or cancels by phase`() {
        assertEquals(MicDictationAction.START, MicDictationControl.tap(DictationPhase.IDLE))
        assertEquals(MicDictationAction.FINISH, MicDictationControl.tap(DictationPhase.LISTENING))
        assertEquals(MicDictationAction.CANCEL, MicDictationControl.tap(DictationPhase.TRANSCRIBING))
        assertEquals(MicDictationAction.CANCEL, MicDictationControl.tap(DictationPhase.FINALIZING))
        assertEquals(
            MicDictationAction.OPEN_APP,
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
    fun `separate cancel is hidden while listening so a walking tap cannot discard`() {
        assertFalse(MicDictationControl.showsSeparateCancel(DictationPhase.IDLE))
        assertFalse(MicDictationControl.showsSeparateCancel(DictationPhase.LISTENING))
        assertTrue(MicDictationControl.showsSeparateCancel(DictationPhase.TRANSCRIBING))
        assertTrue(MicDictationControl.showsSeparateCancel(DictationPhase.FINALIZING))
        assertFalse(MicDictationControl.showsSeparateCancel(DictationPhase.FAILED))
    }

    @Test
    fun `a failed empty transcript does not lock the keyboard menu`() {
        assertTrue(MicDictationControl.allowsMenu(DictationPhase.IDLE))
        assertTrue(MicDictationControl.allowsMenu(DictationPhase.FAILED))
        assertTrue(MicDictationControl.allowsMenu(DictationPhase.INSERTED))
        assertFalse(MicDictationControl.allowsMenu(DictationPhase.LISTENING))
        assertFalse(MicDictationControl.allowsMenu(DictationPhase.TRANSCRIBING))
    }

    @Test
    fun `a start tap looks busy until the controller answers it`() {
        val idle = DictationState()
        val session = UUID.randomUUID()

        assertTrue(MicDictationControl.awaitingTap(idle, idle))
        assertFalse(
            MicDictationControl.awaitingTap(
                idle,
                DictationState(sessionId = session, phase = DictationPhase.LISTENING),
            ),
        )
        assertFalse(
            MicDictationControl.awaitingTap(idle, DictationState(phase = DictationPhase.PERMISSION_REPAIR)),
        )
    }

    @Test
    fun `restarting from a failure waits through the reset to idle`() {
        val failed = DictationState(sessionId = UUID.randomUUID(), phase = DictationPhase.FAILED)

        assertTrue(MicDictationControl.awaitingTap(failed, failed))
        assertTrue(MicDictationControl.awaitingTap(failed, DictationState()))
        assertFalse(
            MicDictationControl.awaitingTap(
                failed,
                DictationState(sessionId = UUID.randomUUID(), phase = DictationPhase.FAILED),
            ),
        )
    }

    @Test
    fun `a finish tap looks busy until capture has stopped`() {
        val listening = DictationState(sessionId = UUID.randomUUID(), phase = DictationPhase.LISTENING)

        assertTrue(MicDictationControl.awaitingTap(listening, listening))
        assertFalse(
            MicDictationControl.awaitingTap(listening, listening.copy(phase = DictationPhase.FINALIZING)),
        )
    }

    @Test
    fun `cancel and open-app taps need no pending state`() {
        val transcribing = DictationState(sessionId = UUID.randomUUID(), phase = DictationPhase.TRANSCRIBING)
        val repair = DictationState(phase = DictationPhase.PERMISSION_REPAIR)

        assertFalse(MicDictationControl.awaitingTap(transcribing, transcribing))
        assertFalse(MicDictationControl.awaitingTap(repair, repair))
    }
}
