package com.vocahq.vocaphone.overlay

import com.vocahq.vocaphone.core.DictationFailure
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.MissingPermission
import org.junit.Assert.assertEquals
import org.junit.Test

/** The bubble's mic was labelled "Dictate" whatever a tap was about to do. */
class BubbleMicLabelTest {

    @Test
    fun theLabelFollowsWhatATapDoes() {
        assertEquals("Dictate", bubbleMicLabel(DictationState()))
        assertEquals("Finish dictation", bubbleMicLabel(DictationState(phase = DictationPhase.LISTENING)))
        assertEquals("Transcribing", bubbleMicLabel(DictationState(phase = DictationPhase.TRANSCRIBING)))
        assertEquals(
            "Retry dictation",
            bubbleMicLabel(
                DictationState(
                    phase = DictationPhase.FAILED,
                    failure = DictationFailure("gateway_unreachable", "x", recoverable = true),
                ),
            ),
        )
        // Nothing was kept, so a tap starts over rather than retrying.
        assertEquals(
            "Dictate",
            bubbleMicLabel(
                DictationState(
                    phase = DictationPhase.FAILED,
                    failure = DictationFailure("empty_transcript", "x", recoverable = false),
                ),
            ),
        )
        assertEquals(
            "Microphone permission needed. Open VocaPhone",
            bubbleMicLabel(
                DictationState(
                    phase = DictationPhase.PERMISSION_REPAIR,
                    missingPermissions = setOf(MissingPermission.MICROPHONE),
                ),
            ),
        )
    }
}
