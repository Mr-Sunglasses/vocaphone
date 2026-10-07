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

    /// A call is named only when one was actually seen.
    @Test func silenceBlamesACallOnlyWhenTheAudioWasInterrupted() {
        let interrupted = SilentCapturePolicy.failureMessage(audioWasInterrupted: true)
        #expect(interrupted.contains("Another app or a call"))

        let quiet = SilentCapturePolicy.failureMessage(audioWasInterrupted: false)
        #expect(quiet.contains("No speech was heard"))
        #expect(!quiet.contains("call"))
        #expect(!quiet.contains("Another app"))
    }
}
