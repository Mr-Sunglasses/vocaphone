package com.vocahq.vocaphone.dictation

import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.data.DiagnosticLog
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MicrophoneForegroundPromoteTest {

    @Test
    fun `retries stay under the startForegroundService timeout`() {
        val budgetMs = MicrophoneForegroundPromote.MAX_ATTEMPTS *
            MicrophoneForegroundPromote.RETRY_DELAY_MS
        assertTrue(budgetMs < 5_000L)
        assertTrue(MicrophoneForegroundPromote.shouldRetry(1))
        assertTrue(
            MicrophoneForegroundPromote.shouldRetry(MicrophoneForegroundPromote.MAX_ATTEMPTS - 1),
        )
        assertFalse(
            MicrophoneForegroundPromote.shouldRetry(MicrophoneForegroundPromote.MAX_ATTEMPTS),
        )
    }

    @Test
    fun `the visible activity is a later fallback not the first retry`() {
        assertFalse(MicrophoneForegroundPromote.shouldLaunchVisibleActivity(1))
        assertTrue(
            MicrophoneForegroundPromote.shouldLaunchVisibleActivity(
                MicrophoneForegroundPromote.LAUNCH_ACTIVITY_AFTER,
            ),
        )
        assertFalse(
            MicrophoneForegroundPromote.shouldLaunchVisibleActivity(
                MicrophoneForegroundPromote.LAUNCH_ACTIVITY_AFTER + 1,
            ),
        )
    }

    @Test
    fun `the keyboard is never sent to the invisible activity`() {
        // A background IME cannot launch it on Android 14+, so the tap vanished.
        assertFalse(MicrophoneForegroundPromote.launchesVisibleStarter(DictationSource.IME))
        assertTrue(MicrophoneForegroundPromote.launchesVisibleStarter(DictationSource.COMPANION_APP))
        assertTrue(MicrophoneForegroundPromote.launchesVisibleStarter(DictationSource.FLOATING))
    }

    @Test
    fun `a refused microphone service is a readable failure, not a silent Ready`() {
        val id = UUID.randomUUID()
        val current = DictationState(language = TranscriptionLanguage.entries.last())
        val state = MicrophoneForegroundPromote.refusedState(current, id)
        assertNotNull(state)
        state!!
        assertEquals(DictationPhase.FAILED, state.phase)
        assertEquals(id, state.sessionId)
        assertEquals(MicrophoneForegroundPromote.REFUSED_MESSAGE, state.statusText)
        assertEquals(current.language, state.language)
        // Nothing was recorded, so there is nothing for Retry to resend.
        assertFalse(state.canRetry)
    }

    @Test
    fun `a refused service replaces an earlier failure or confirmation`() {
        for (phase in listOf(DictationPhase.IDLE, DictationPhase.FAILED, DictationPhase.INSERTED)) {
            val state = MicrophoneForegroundPromote.refusedState(DictationState(phase = phase), UUID.randomUUID())
            assertEquals(phase.name, DictationPhase.FAILED, state?.phase)
        }
    }

    @Test
    fun `a refused service never paints over a dictation that is running`() {
        for (phase in DictationPhase.entries.filter { it.isBusy }) {
            assertNull(
                phase.name,
                MicrophoneForegroundPromote.refusedState(DictationState(phase = phase), UUID.randomUUID()),
            )
        }
    }

    @Test
    fun `a refused service leaves a session whose pipeline is still running alone`() {
        // The pipeline can still be finishing after its phase left the busy
        // set (an INSERTED tail writing history); it owns the state until done.
        for (phase in listOf(DictationPhase.IDLE, DictationPhase.INSERTED, DictationPhase.FAILED)) {
            assertNull(
                phase.name,
                MicrophoneForegroundPromote.refusedState(
                    DictationState(phase = phase),
                    UUID.randomUUID(),
                    pipelineActive = true,
                ),
            )
        }
    }

    @Test
    fun `an older linger timer cannot clear the refusal, its own one does`() {
        // A FAILED from an earlier dictation set a 3 s timer; the refusal lands
        // before it fires and must outlive it.
        val earlier = UUID.randomUUID()
        val refused = UUID.randomUUID()
        val refusal = MicrophoneForegroundPromote.refusedState(
            DictationState(sessionId = earlier, phase = DictationPhase.FAILED),
            refused,
        )!!
        assertEquals(refusal, afterLinger(refusal, earlier, DictationPhase.FAILED))
        assertEquals(
            DictationPhase.IDLE,
            afterLinger(refusal, refused, DictationPhase.FAILED).phase,
        )
    }

    @Test
    fun `a refusal is logged under its own category, not as unknown`() {
        assertTrue(MicrophoneForegroundPromote.ERROR_CATEGORY in DiagnosticLog.ERROR_CATEGORIES)
        val directory = Files.createTempDirectory("vocaphone-diagnostics").toFile()
        try {
            val log = DiagnosticLog(directory.resolve("events.log"), nowMillis = { 1L })
            log.recordError(MicrophoneForegroundPromote.ERROR_CATEGORY, DictationSource.IME.name)
            assertTrue(log.read().contains("event=error value=microphone_service source=IME"))
        } finally {
            directory.deleteRecursively()
        }
    }
}
