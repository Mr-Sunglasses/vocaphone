package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.DictationPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
