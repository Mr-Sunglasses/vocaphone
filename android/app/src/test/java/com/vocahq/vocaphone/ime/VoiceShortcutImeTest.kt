package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.DictationPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceShortcutImeTest {

    @Test
    fun `only an auxiliary voice subtype is the system shortcut`() {
        assertTrue(VoiceShortcutIme.isVoiceShortcutSubtype("voice", auxiliary = true))
        assertTrue(VoiceShortcutIme.isVoiceShortcutSubtype("VOICE", auxiliary = true))
        assertFalse(VoiceShortcutIme.isVoiceShortcutSubtype("voice", auxiliary = false))
        assertFalse(VoiceShortcutIme.isVoiceShortcutSubtype("keyboard", auxiliary = true))
        assertFalse(VoiceShortcutIme.isVoiceShortcutSubtype("keyboard", auxiliary = false))
        assertFalse(VoiceShortcutIme.isVoiceShortcutSubtype(null, auxiliary = true))
        assertFalse(VoiceShortcutIme.isVoiceShortcutSubtype("", auxiliary = true))
    }

    @Test
    fun `auto-start requires the shortcut, a dictation field, and a free pipeline`() {
        assertTrue(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = true,
                isBusy = false,
                alreadyRequested = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = false,
                dictationAllowed = true,
                isBusy = false,
                alreadyRequested = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = false,
                isBusy = false,
                alreadyRequested = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = true,
                isBusy = true,
                alreadyRequested = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = true,
                isBusy = false,
                alreadyRequested = true,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = true,
                isBusy = false,
                alreadyRequested = false,
                inputViewShown = false,
            ),
        )
    }

    @Test
    fun `auto-start waits while the IME window is not yet visible`() {
        assertTrue(
            VoiceShortcutIme.shouldWaitForInputView(
                isVoiceShortcut = true,
                alreadyRequested = false,
                inputViewShown = false,
                waitAttempts = 0,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldWaitForInputView(
                isVoiceShortcut = true,
                alreadyRequested = false,
                inputViewShown = true,
                waitAttempts = 0,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldWaitForInputView(
                isVoiceShortcut = true,
                alreadyRequested = true,
                inputViewShown = false,
                waitAttempts = 0,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldWaitForInputView(
                isVoiceShortcut = false,
                alreadyRequested = false,
                inputViewShown = false,
                waitAttempts = 0,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldWaitForInputView(
                isVoiceShortcut = true,
                alreadyRequested = false,
                inputViewShown = false,
                waitAttempts = VoiceShortcutIme.MAX_WINDOW_WAITS,
            ),
        )
    }

    @Test
    fun `the normal keyboard never hands back to a previous IME`() {
        val phases = listOf(
            DictationPhase.IDLE,
            DictationPhase.LISTENING,
            DictationPhase.INSERTED,
            DictationPhase.FAILED,
            DictationPhase.READY_TO_INSERT,
        )
        for (phase in phases) {
            assertFalse(
                "non-shortcut $phase should stay on VocaPhone",
                VoiceShortcutIme.shouldReturnToPreviousIme(
                    isVoiceShortcut = false,
                    ownedSession = true,
                    sessionLeftIdle = true,
                    phase = phase,
                ),
            )
        }
    }

    @Test
    fun `shortcut returns after insert, cancel idle, or failed empty`() {
        assertTrue(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.INSERTED,
            ),
        )
        assertTrue(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.FAILED,
            ),
        )
        assertTrue(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.IDLE,
            ),
        )
        assertTrue(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = false,
                phase = DictationPhase.INSERTED,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.READY_TO_INSERT,
            ),
        )
    }

    @Test
    fun `shortcut does not bounce back before listening starts`() {
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = false,
                phase = DictationPhase.IDLE,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = false,
                phase = DictationPhase.LISTENING,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.LISTENING,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.TRANSCRIBING,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.PERMISSION_REPAIR,
            ),
        )
    }

    @Test
    fun `a session this shortcut did not start does not steal the keyboard`() {
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = false,
                sessionLeftIdle = true,
                phase = DictationPhase.INSERTED,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = false,
                sessionLeftIdle = true,
                phase = DictationPhase.IDLE,
            ),
        )
    }

    @Test
    fun `password and other rejected fields still hand back`() {
        assertTrue(
            VoiceShortcutIme.shouldReturnWhenDictationRejected(
                isVoiceShortcut = true,
                dictationAllowed = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnWhenDictationRejected(
                isVoiceShortcut = true,
                dictationAllowed = true,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnWhenDictationRejected(
                isVoiceShortcut = false,
                dictationAllowed = false,
            ),
        )
    }

    @Test
    fun `sensitive rejected fields hand back immediately`() {
        assertEquals(
            VoiceShortcutIme.RejectedHandback.IMMEDIATE,
            VoiceShortcutIme.rejectedHandback(
                isVoiceShortcut = true,
                dictationAllowed = false,
                sensitive = true,
            ),
        )
        assertEquals(
            VoiceShortcutIme.RejectedHandback.NONE,
            VoiceShortcutIme.rejectedHandback(
                isVoiceShortcut = true,
                dictationAllowed = true,
                sensitive = true,
            ),
        )
    }

    @Test
    fun `late capable EditorInfo after GUIDED cancels bounce and starts`() {
        // Picker / unknown field first → GUIDED delay is armed.
        val guidedDecision = VoiceShortcutIme.rejectedHandback(
            isVoiceShortcut = true,
            dictationAllowed = false,
            sensitive = false,
        )
        assertEquals(VoiceShortcutIme.RejectedHandback.GUIDED, guidedDecision)
        val guided = VoiceShortcutIme.rejectedHandbackEffects(
            decision = guidedDecision,
            alreadyReturned = false,
        )!!
        assertTrue(guided.scheduleDelayedHandback)
        assertTrue(guided.showGuidance)
        assertFalse(guided.requestAutoStart)
        assertFalse(guided.returnImmediately)

        var flags = VoiceShortcutIme.applyRejectedHandbackEffects(
            VoiceShortcutIme.RejectedHandbackFlags(),
            guided,
        )
        assertTrue(flags.delayedPending)
        assertTrue(flags.guidanceVisible)

        // A late StartInput can still deliver a dictation-capable EditorInfo.
        // Live re-check must flip to NONE so the service clears the delayed
        // bounce + guidance and starts — matching the delayed NONE arm.
        val noneDecision = VoiceShortcutIme.rejectedHandback(
            isVoiceShortcut = true,
            dictationAllowed = true,
            sensitive = false,
        )
        assertEquals(VoiceShortcutIme.RejectedHandback.NONE, noneDecision)
        val cleared = VoiceShortcutIme.rejectedHandbackEffects(
            decision = noneDecision,
            alreadyReturned = false,
        )!!
        assertTrue(cleared.cancelDelayedHandback)
        assertFalse(cleared.scheduleDelayedHandback)
        assertFalse(cleared.showGuidance)
        assertTrue(cleared.requestAutoStart)
        assertFalse(cleared.returnImmediately)

        flags = VoiceShortcutIme.applyRejectedHandbackEffects(flags, cleared)
        assertFalse("pending Handler bounce must clear", flags.delayedPending)
        assertFalse("guidance chrome must clear", flags.guidanceVisible)
        assertTrue(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = true,
                isBusy = false,
                alreadyRequested = false,
                inputViewShown = true,
            ),
        )
    }

    @Test
    fun `guided handback is a no-op after return and immediate clears pending`() {
        assertEquals(
            null,
            VoiceShortcutIme.rejectedHandbackEffects(
                decision = VoiceShortcutIme.RejectedHandback.GUIDED,
                alreadyReturned = true,
            ),
        )
        val immediate = VoiceShortcutIme.rejectedHandbackEffects(
            decision = VoiceShortcutIme.RejectedHandback.IMMEDIATE,
            alreadyReturned = false,
        )!!
        val flags = VoiceShortcutIme.applyRejectedHandbackEffects(
            VoiceShortcutIme.RejectedHandbackFlags(
                delayedPending = true,
                guidanceVisible = true,
            ),
            immediate,
        )
        assertFalse(flags.delayedPending)
        assertFalse(flags.guidanceVisible)
        assertTrue(immediate.returnImmediately)
        assertFalse(immediate.requestAutoStart)
    }

    @Test
    fun `picker and unknown editors use guided delayed handback`() {
        assertEquals(
            VoiceShortcutIme.RejectedHandback.GUIDED,
            VoiceShortcutIme.rejectedHandback(
                isVoiceShortcut = true,
                dictationAllowed = false,
                sensitive = false,
            ),
        )
        assertEquals(
            VoiceShortcutIme.RejectedHandback.NONE,
            VoiceShortcutIme.rejectedHandback(
                isVoiceShortcut = false,
                dictationAllowed = false,
                sensitive = false,
            ),
        )
        assertTrue(VoiceShortcutIme.REJECTED_HANDBACK_DELAY_MS > 0L)
        assertEquals(
            "Open a text field, then use the host keyboard mic",
            VoiceShortcutIme.REJECTED_HANDBACK_GUIDANCE,
        )
    }

    @Test
    fun `hiding the shortcut view returns even if dictation never started`() {
        assertTrue(
            VoiceShortcutIme.shouldReturnWhenViewFinishes(
                isVoiceShortcut = true,
                alreadyReturned = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnWhenViewFinishes(
                isVoiceShortcut = true,
                alreadyReturned = true,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnWhenViewFinishes(
                isVoiceShortcut = false,
                alreadyReturned = false,
            ),
        )
    }

    @Test
    fun `a hide during auto-start does not bounce back to the typing keyboard`() {
        assertTrue(
            VoiceShortcutIme.shouldKeepShortcutSession(
                isVoiceShortcut = true,
                startRequested = true,
                sessionLeftIdle = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldKeepShortcutSession(
                isVoiceShortcut = true,
                startRequested = true,
                sessionLeftIdle = true,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldKeepShortcutSession(
                isVoiceShortcut = true,
                startRequested = false,
                sessionLeftIdle = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldKeepShortcutSession(
                isVoiceShortcut = false,
                startRequested = true,
                sessionLeftIdle = false,
            ),
        )
    }

    @Test
    fun `the voice shortcut does not take a microphone foreground service`() {
        assertFalse(VoiceShortcutIme.usesMicrophoneForegroundService(isVoiceShortcut = true))
        assertTrue(VoiceShortcutIme.usesMicrophoneForegroundService(isVoiceShortcut = false))
    }

    @Test
    fun `voice mode string matches method xml`() {
        assertEquals("voice", VoiceShortcutIme.MODE_VOICE)
    }

    @Test
    fun `publishing subtypes is a no-op without a manager or info`() {
        VoiceShortcutIme.publishEnabledSubtypes(null, "com.vocahq.vocaphone/.ime.VocaPhoneInputMethodService", null)
    }
}
