package com.vocahq.vocaphone.ime

import android.os.Build
import android.view.inputmethod.InputMethodInfo
import android.view.inputmethod.InputMethodManager
import com.vocahq.vocaphone.core.DictationPhase

/**
 * Decisions for the auxiliary voice subtype other keyboards hand off to.
 *
 * HeliBoard / Gboard-style mic keys call
 * [android.view.inputmethod.InputMethodManager.getShortcutInputMethodsAndSubtypes],
 * which only lists IMEs that declare a voice-mode auxiliary subtype.
 */
internal object VoiceShortcutIme {
    const val MODE_VOICE = "voice"
    const val MAX_WINDOW_WAITS = 10
    const val WINDOW_WAIT_DELAY_MS = 50L

    fun isVoiceShortcutSubtype(mode: String?, auxiliary: Boolean): Boolean =
        auxiliary && !mode.isNullOrEmpty() && mode.equals(MODE_VOICE, ignoreCase = true)

    /** Hash codes of every subtype, so the voice shortcut is explicitly enabled. */
    fun subtypeHashes(imi: InputMethodInfo): IntArray =
        IntArray(imi.subtypeCount) { imi.getSubtypeAt(it).hashCode() }

    fun publishEnabledSubtypes(imm: InputMethodManager?, imiId: String, imi: InputMethodInfo?) {
        if (imm == null || imi == null) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        imm.setExplicitlyEnabledInputMethodSubtypes(imiId, subtypeHashes(imi))
    }

    fun shouldAutoStart(
        isVoiceShortcut: Boolean,
        dictationAllowed: Boolean,
        isBusy: Boolean,
        alreadyRequested: Boolean,
        inputViewShown: Boolean = true,
    ): Boolean = isVoiceShortcut && dictationAllowed && !isBusy && !alreadyRequested && inputViewShown

    /**
     * HeliBoard hands off before our IME window counts as visible, and
     * startForeground(MICROPHONE) on targetSdk 36 throws until it does.
     */
    fun shouldWaitForInputView(
        isVoiceShortcut: Boolean,
        alreadyRequested: Boolean,
        inputViewShown: Boolean,
        waitAttempts: Int,
    ): Boolean = isVoiceShortcut && !alreadyRequested && !inputViewShown &&
        waitAttempts < MAX_WINDOW_WAITS

    /**
     * Whether this activation should hand back to the typing keyboard.
     *
     * [ownedSession] is the voice-shortcut flag, not "VocaPhone is the normal
     * keyboard". IDLE is a return only after the session left idle — otherwise
     * auto-start would bounce back before listening began.
     *
     * READY_TO_INSERT is an IME insert that already failed. Stay on the
     * shortcut chrome so retry and the transcript are still on screen.
     */
    fun shouldReturnToPreviousIme(
        isVoiceShortcut: Boolean,
        ownedSession: Boolean,
        sessionLeftIdle: Boolean,
        phase: DictationPhase,
    ): Boolean {
        if (!isVoiceShortcut || !ownedSession) return false
        return when (phase) {
            DictationPhase.INSERTED,
            DictationPhase.FAILED,
            -> true
            DictationPhase.IDLE -> sessionLeftIdle
            else -> false
        }
    }

    fun shouldReturnWhenDictationRejected(
        isVoiceShortcut: Boolean,
        dictationAllowed: Boolean,
    ): Boolean = isVoiceShortcut && !dictationAllowed

    fun shouldReturnWhenViewFinishes(
        isVoiceShortcut: Boolean,
        alreadyReturned: Boolean,
    ): Boolean = isVoiceShortcut && !alreadyReturned

    /**
     * A HeliBoard handoff can hide our input view for a frame while the
     * microphone service is still coming up. Returning then would make
     * HeliBoard the current IME again and leave insert with no connection.
     */
    fun shouldKeepShortcutSession(
        isVoiceShortcut: Boolean,
        startRequested: Boolean,
        sessionLeftIdle: Boolean,
    ): Boolean = isVoiceShortcut && startRequested && !sessionLeftIdle

    /**
     * HeliBoard handoff does not get while-in-use for a microphone FGS
     * (targetSdk 36). The IME window is visible, so capture can run without
     * it; we cancel when the view finishes.
     */
    fun usesMicrophoneForegroundService(isVoiceShortcut: Boolean): Boolean = !isVoiceShortcut
}
