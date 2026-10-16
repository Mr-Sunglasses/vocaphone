package com.vocahq.vocaphone.dictation

import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingNoticeTest {

    @Test
    fun whileTheMicrophoneIsOpenItSaysRecordingAndOffersFinish() {
        val notice = RecordingNotice.of(DictationState(phase = DictationPhase.LISTENING))
        assertEquals("Recording", notice.title)
        assertTrue(notice.offersFinish)
        assertEquals(
            "One minute left",
            RecordingNotice.of(DictationState(phase = DictationPhase.LISTENING, approachingLimit = true)).text,
        )
    }

    @Test
    fun afterItClosesThereIsNothingToFinish() {
        val notice = RecordingNotice.of(DictationState(phase = DictationPhase.TRANSCRIBING))
        assertEquals("Transcribing", notice.text)
        assertFalse(notice.offersFinish)
    }
}
