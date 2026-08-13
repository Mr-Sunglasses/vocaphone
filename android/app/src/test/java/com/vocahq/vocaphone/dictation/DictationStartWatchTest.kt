package com.vocahq.vocaphone.dictation

import com.vocahq.vocaphone.core.DictationPhase
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DictationStartWatchTest {

    @Test
    fun `holding the microphone settles the start`() {
        assertTrue(DictationStartWatch.hasSettled(DictationPhase.LISTENING))
        assertTrue(DictationStartWatch.hasSettled(DictationPhase.FINALIZING))
    }

    /**
     * The service holds a microphone foreground service from before capture
     * begins, so an outcome that never reaches the microphone has to end the
     * wait. Leaving it to the timeout showed "VocaPhone is recording" and the
     * system microphone indicator for ten seconds over a dictation that never
     * started — which is what tapping the mic before setup was finished did.
     */
    @Test
    fun `an outcome that never records settles the start too`() {
        assertTrue(DictationStartWatch.hasSettled(DictationPhase.PERMISSION_REPAIR))
        assertTrue(DictationStartWatch.hasSettled(DictationPhase.FAILED))
    }

    /**
     * Idle is the phase the state is already in when the service subscribes, so
     * treating it as an outcome would abandon every dictation before it began.
     */
    @Test
    fun `idle is not an outcome`() {
        assertFalse(DictationStartWatch.hasSettled(DictationPhase.IDLE))
    }

    /**
     * These arrive after the microphone has been released. Reaching one without
     * passing through LISTENING would mean capture never happened.
     */
    @Test
    fun `phases past the microphone do not stand in for it`() {
        for (phase in listOf(
            DictationPhase.UPLOADING,
            DictationPhase.TRANSCRIBING,
            DictationPhase.READY_TO_INSERT,
            DictationPhase.INSERTING,
            DictationPhase.INSERTED,
        )) {
            assertFalse("$phase", DictationStartWatch.hasSettled(phase))
        }
    }

    @Test
    fun `terminal phases release the foreground service after inference`() {
        assertTrue(DictationPhase.READY_TO_INSERT.isTerminal)
        assertTrue(DictationPhase.INSERTED.isTerminal)
        assertTrue(DictationPhase.FAILED.isTerminal)
        assertFalse(DictationPhase.TRANSCRIBING.isTerminal)
        assertFalse(DictationPhase.INSERTING.isTerminal)
    }
}
