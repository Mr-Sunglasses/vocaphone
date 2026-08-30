package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DictateCopyTest {

    @Test
    fun idleDoesNotRepeatTapToDictate() {
        assertFalse(showDictateStatus(DictationPhase.IDLE))
        assertTrue(showDictateStatus(DictationPhase.LISTENING))
        assertTrue(showDictateStatus(DictationPhase.TRANSCRIBING))
        assertFalse(showDictateStatus(DictationPhase.FAILED))
    }

    @Test
    fun modelChipNamesTheOnDeviceModelOrGateway() {
        assertEquals(
            DictateCopy.NO_MODEL,
            dictateModelChipLabel(VocaPhoneSettings(localTranscriptionEnabled = true)),
        )
        assertEquals(
            DictateCopy.GATEWAY,
            dictateModelChipLabel(VocaPhoneSettings(localTranscriptionEnabled = false)),
        )
        assertEquals(
            "Moonshine v2 Tiny English",
            dictateModelChipLabel(
                VocaPhoneSettings(
                    localTranscriptionEnabled = true,
                    localModelId = "moonshine-v2-tiny-en",
                ),
            ),
        )
        assertEquals("Moonshine v2 Tiny", compactModelChipLabel("Moonshine v2 Tiny English"))
        assertEquals("Parakeet TDT 0.6B", compactModelChipLabel("Parakeet TDT 0.6B"))
    }

    @Test
    fun actionLabelsStayShort() {
        assertEquals("Dictate", DictateCopy.DICTATE)
        assertEquals("Clear", DictateCopy.CLEAR)
        assertFalse(DictateCopy.DICTATE.contains("Tap"))
        assertFalse(DictateCopy.DICTATE.contains("Start dictation"))
    }

    @Test
    fun scratchpadHintLeavesOnceThereIsTextOrARecording() {
        assertEquals(
            "Inserted at the cursor. Nothing here is uploaded.",
            DictateCopy.HINT,
        )
        assertTrue(showScratchpadHint("", DictationPhase.IDLE))
        assertFalse(showScratchpadHint("hello", DictationPhase.IDLE))
        assertFalse(showScratchpadHint("", DictationPhase.LISTENING))
        assertFalse(showScratchpadHint("", DictationPhase.TRANSCRIBING))
        assertTrue(showScratchpadHint("", DictationPhase.FAILED))
    }
}
