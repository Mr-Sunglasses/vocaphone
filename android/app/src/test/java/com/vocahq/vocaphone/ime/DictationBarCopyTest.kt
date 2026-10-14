package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.DictationFailure
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.MissingPermission
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DictationBarCopyTest {

    private val gatewayDown = DictationState(
        sessionId = UUID.randomUUID(),
        phase = DictationPhase.FAILED,
        failure = DictationFailure(
            "gateway_unreachable",
            "Could not reach your gateway. Check the address and your network.",
            recoverable = true,
        ),
    )

    private fun detail(state: DictationState) = DictationBarCopy.detail(state, idleDetail = "", busyDetail = "busy")

    @Test
    fun `a failure shows a short title and offers Retry only when the recording was kept`() {
        assertEquals("Gateway unreachable", DictationBarCopy.status(gatewayDown, "0:03"))
        assertEquals(gatewayDown.failure!!.message, detail(gatewayDown))
        assertEquals(DictationBarAction.RETRY, DictationBarCopy.action(gatewayDown))

        val nothingKept = gatewayDown.copy(failure = DictationFailure("empty_transcript", "Nothing.", false))
        assertNull(DictationBarCopy.action(nothingKept))
    }

    @Test
    fun `a transcript saved to History offers Insert`() {
        val saved = DictationState(phase = DictationPhase.READY_TO_INSERT, transcript = "Meet at\nnoon")
        assertEquals(DictationBarCopy.SAVED_TITLE, DictationBarCopy.status(saved, "0:00"))
        assertEquals("Meet at noon", detail(saved))
        assertEquals(DictationBarAction.INSERT, DictationBarCopy.action(saved))
        assertNull(DictationBarCopy.action(saved.copy(transcript = " ")))
    }

    @Test
    fun `the keyboard never counts down to the recording limit`() {
        val listening = DictationState(phase = DictationPhase.LISTENING, partialTranscript = "hello")
        val nearLimit = listening.copy(approachingLimit = true)
        assertEquals("hello", detail(nearLimit))
        assertEquals("Listening", DictationBarCopy.announcement(nearLimit))
        assertEquals(
            "Tap the red button to finish",
            detail(nearLimit.copy(partialTranscript = "")),
        )
    }

    @Test
    fun `a repair says what is missing and what a tap does`() {
        val repair = DictationState(
            phase = DictationPhase.PERMISSION_REPAIR,
            missingPermissions = setOf(MissingPermission.MODEL_DOWNLOADING),
            modelDownloadProgress = 42,
        )
        assertEquals("Model downloading", DictationBarCopy.status(repair, "0:00"))
        assertEquals("42% · Tap to see the download", detail(repair))
    }

    @Test
    fun `TalkBack hears phase changes, not the timer or the partial transcript`() {
        val early = DictationState(phase = DictationPhase.LISTENING, recordedMillis = 1_000, partialTranscript = "a")
        val later = early.copy(recordedMillis = 9_000, partialTranscript = "a longer sentence", level = 0.7f)
        assertEquals(DictationBarCopy.announcement(early), DictationBarCopy.announcement(later))
        assertNull(DictationBarCopy.announcement(DictationState()))
        assertEquals(
            "Gateway unreachable. Could not reach your gateway. Check the address and your network.",
            DictationBarCopy.announcement(gatewayDown),
        )
        val downloading = DictationState(
            phase = DictationPhase.PERMISSION_REPAIR,
            missingPermissions = setOf(MissingPermission.MODEL_DOWNLOADING),
            modelDownloadProgress = 10,
        )
        assertEquals(
            DictationBarCopy.announcement(downloading),
            DictationBarCopy.announcement(downloading.copy(modelDownloadProgress = 11)),
        )
    }

    @Test
    fun `the spinner's label points at the cancel button instead of claiming to cancel`() {
        val busy = DictationState(phase = DictationPhase.TRANSCRIBING)
        assertEquals("Transcribing. Use Cancel dictation to discard it", DictationBarCopy.micDescription(busy, true))
        assertEquals("Start a new dictation", DictationBarCopy.micDescription(gatewayDown, true))
        assertEquals("Dictation unavailable", DictationBarCopy.micDescription(busy, false))
    }

    @Test
    fun `the voice shortcut reads its guidance in full but only the phase while dictating`() {
        val idle = DictationState()
        assertEquals(
            "Voice shortcut. ${VoiceShortcutIme.REJECTED_HANDBACK_GUIDANCE}",
            DictationBarCopy.shortcutAnnouncement(
                state = idle,
                status = "Voice shortcut",
                detail = VoiceShortcutIme.REJECTED_HANDBACK_GUIDANCE,
                guidance = true,
            ),
        )
        assertEquals(
            "VocaPhone. Voice input",
            DictationBarCopy.shortcutAnnouncement(idle, "VocaPhone", "Voice input", guidance = false),
        )
        val listening = DictationState(phase = DictationPhase.LISTENING, partialTranscript = "meet at")
        assertEquals(
            "Listening",
            DictationBarCopy.shortcutAnnouncement(listening, "Listening · 0:04", "meet at", guidance = false),
        )
    }
}
