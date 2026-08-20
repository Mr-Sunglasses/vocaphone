package com.vocahq.vocaphone.audio

import com.vocahq.vocaphone.core.DictationTone
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TonePreviewTest {

    @Test
    fun `preview does not start AudioRecord`() {
        assertFalse(TonePreview.OPENS_MICROPHONE)
    }

    @Test
    fun `Off stays idle`() {
        assertFalse(TonePreview.nextListening(currentlyListening = false, tone = DictationTone.OFF))
        assertFalse(TonePreview.nextListening(currentlyListening = true, tone = DictationTone.OFF))
    }

    @Test
    fun `first tap starts listening and second tap stops`() {
        val afterStart = TonePreview.nextListening(false, DictationTone.VOCA)
        val afterStop = TonePreview.nextListening(afterStart, DictationTone.VOCA)

        assertTrue(afterStart)
        assertFalse(afterStop)
    }
}
