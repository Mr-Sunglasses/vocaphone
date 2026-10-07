import Testing

/// What happens to Quick Dictation and to a silent recording when another app
/// takes the audio session.
struct CaptureInterruptionTests {
    private func rearm(
        shouldResume: Bool = true,
        enabled: Bool = true,
        foreground: Bool = false,
        wasReady: Bool = true
    ) -> Bool {
        QuickDictationInterruptionPolicy.shouldRearm(
            shouldResume: shouldResume,
            quickDictationEnabled: enabled,
            appIsForeground: foreground,
            wasReadyWhenInterrupted: wasReady
        )
    }

    /// The common case: the user was in another app with Quick Dictation
    /// armed, took a call, and hung up. Standby used to stay off until they
    /// next opened vocaphone.
    @Test func standbyComesBackAfterACallInTheBackground() {
        #expect(rearm(foreground: false, wasReady: true))
    }

    @Test func theForegroundBehaviourIsUnchanged() {
        #expect(rearm(foreground: true, wasReady: false))
        #expect(rearm(foreground: true, wasReady: true))
    }

    /// iOS withholding `.shouldResume` means stay quiet, wherever the app is.
    @Test func withoutShouldResumeNothingRearms() {
        #expect(!rearm(shouldResume: false, foreground: false))
        #expect(!rearm(shouldResume: false, foreground: true))
    }

    /// The background never opens the microphone for a window nobody had.
    @Test func theBackgroundRestoresOnlyWhatWasRunning() {
        #expect(!rearm(foreground: false, wasReady: false))
    }

    @Test func turningQuickDictationOffWins() {
        #expect(!rearm(enabled: false, foreground: true))
        #expect(!rearm(enabled: false, foreground: false, wasReady: true))
    }

    // MARK: - Across the interruption

    private func endInterruption(
        _ interruption: inout QuickDictationInterruption,
        shouldResume: Bool = true,
        armable: Bool = true,
        foreground: Bool = false
    ) -> Bool {
        interruption.ended(
            shouldResume: shouldResume,
            quickDictationArmable: armable,
            appIsForeground: foreground
        )
    }

    /// Standby is torn down by the interruption itself, so what was running
    /// is remembered from its beginning to its end.
    @Test func standbyRunningWhenTheCallCameIsRestoredWhenItEnds() {
        var interruption = QuickDictationInterruption()
        interruption.began(running: true)
        #expect(endInterruption(&interruption))
        // Consumed: the next end, with nothing running, restores nothing.
        #expect(!endInterruption(&interruption))
    }

    @Test func nothingRunningWhenTheCallCameStaysOffInTheBackground() {
        var interruption = QuickDictationInterruption()
        interruption.began(running: false)
        #expect(!endInterruption(&interruption))
    }

    /// A call, then Siri before the call's end arrives: by the second
    /// beginning standby is already gone, because of the call.
    @Test func aSecondInterruptionKeepsWhatTheFirstFound() {
        var interruption = QuickDictationInterruption()
        interruption.began(running: true)
        interruption.began(running: false)
        #expect(endInterruption(&interruption))
    }

    /// Pausing from the Live Activity, or turning Quick Dictation off, during
    /// the call is the user ending the window; the end of the call does not
    /// override it.
    @Test func aPauseDuringTheCallKeepsStandbyOff() {
        var paused = QuickDictationInterruption()
        paused.began(running: true)
        paused.forget()
        #expect(!endInterruption(&paused))

        // The pause flag alone blocks it as well, foreground or not.
        var flagged = QuickDictationInterruption()
        flagged.began(running: true)
        #expect(!endInterruption(&flagged, armable: false))
        flagged.began(running: true)
        #expect(!endInterruption(&flagged, armable: false, foreground: true))
    }

    /// iOS does not deliver an end for every beginning. Once standby has been
    /// armed again, a later, unrelated interruption must not bring back a
    /// window that was not running when it began.
    @Test func anInterruptionThatNeverEndedIsForgottenOnceStandbyIsBack() {
        var interruption = QuickDictationInterruption()
        interruption.began(running: true)
        interruption.forget()
        interruption.began(running: false)
        #expect(!endInterruption(&interruption))
    }

    @Test func withoutShouldResumeTheInterruptionIsStillForgotten() {
        var interruption = QuickDictationInterruption()
        interruption.began(running: true)
        #expect(!endInterruption(&interruption, shouldResume: false))
        #expect(!interruption.wasRunning)
    }

    /// A call is named only when one was actually seen.
    @Test func silenceBlamesACallOnlyWhenTheAudioWasInterrupted() {
        let interrupted = SilentCapturePolicy.failureMessage(audioWasInterrupted: true)
        #expect(interrupted.contains("Another app or a call"))

        let quiet = SilentCapturePolicy.failureMessage(audioWasInterrupted: false)
        #expect(quiet.contains("No speech was heard"))
        #expect(!quiet.contains("call"))
        #expect(!quiet.contains("was using the microphone"))
        // Not asserted, but not ruled out either: a mixing session can be
        // handed zeros without an interruption.
        #expect(quiet.contains("another app"))
    }
}
