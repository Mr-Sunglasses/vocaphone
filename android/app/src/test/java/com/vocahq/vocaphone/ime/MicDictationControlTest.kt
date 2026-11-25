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

class MicPressTest {
    private fun press(phase: DictationPhase = DictationPhase.IDLE, menu: Boolean = true) =
        MicPress(phase, menuAllowed = menu, slopPx = SLOP)

    @Test
    fun `a quick tap is still a tap`() {
        val p = press()
        assertNull(p.move(3f, 2f))
        assertEquals(MicPressEvent.TAP, p.release())
    }

    @Test
    fun `a still hold on an idle mic is push to talk`() {
        val p = press()
        assertEquals(MicPressEvent.HOLD_START, p.holdElapsed())
        // Moving while talking changes nothing.
        assertNull(p.move(SLOP * 3, 0f))
        assertEquals(MicPressEvent.HOLD_END, p.release())
    }

    @Test
    fun `a slide before the hold opens the menu instead`() {
        val p = press()
        assertEquals(MicPressEvent.OPEN_MENU, p.move(0f, -(SLOP + 1f)))
        assertNull(p.move(0f, -SLOP * 4))
        assertNull(p.holdElapsed())
        assertNull(p.release())
    }

    @Test
    fun `without a menu a slide just cancels the tap`() {
        val p = press(menu = false)
        assertNull(p.move(SLOP * 2, 0f))
        assertNull(p.holdElapsed())
        assertNull(p.release())
    }

    @Test
    fun `while busy a long press still discards and a tap still finishes`() {
        val listening = press(DictationPhase.LISTENING)
        assertNull(listening.holdElapsed())
        assertEquals(MicPressEvent.CANCEL, listening.longPressElapsed())
        assertNull(listening.release())
        assertEquals(MicPressEvent.TAP, press(DictationPhase.LISTENING).release())
        // Moving on the Stop button is not a menu.
        val stop = press(DictationPhase.LISTENING)
        assertNull(stop.move(SLOP * 2, 0f))
        assertEquals(MicPressEvent.TAP, stop.release())
    }

    @Test
    fun `idle mics have no long-press cancel and repairs only tap`() {
        assertNull(press().longPressElapsed())
        val repair = press(DictationPhase.PERMISSION_REPAIR)
        assertNull(repair.holdElapsed())
        assertNull(repair.move(SLOP * 2, 0f))
        assertEquals(MicPressEvent.TAP, repair.release())
    }

    private companion object {
        const val SLOP = 10f
    }
}
