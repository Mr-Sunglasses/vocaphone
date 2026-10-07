import Foundation

/// What the containing app does when the audio session comes back after an
/// interruption — a phone call, FaceTime, Siri, an alarm.
///
/// Losing the audio session ends Quick Dictation's standby, and the end of the
/// interruption used to bring it back only while vocaphone was on screen. The
/// common case is the opposite one: the user is in another app, takes a call,
/// and returns to typing — to a keyboard that now opens vocaphone for every
/// dictation until they think to open it themselves.
enum QuickDictationInterruptionPolicy {
    /// - Parameters:
    ///   - shouldResume: iOS's `.shouldResume` option. Without it the system is
    ///     saying the session should stay quiet, and it does.
    ///   - wasReadyWhenInterrupted: standby — or a dictation — was running when
    ///     the interruption began. In the background, only that is restored:
    ///     the microphone is never opened there for a window nobody had.
    static func shouldRearm(
        shouldResume: Bool,
        quickDictationEnabled: Bool,
        appIsForeground: Bool,
        wasReadyWhenInterrupted: Bool
    ) -> Bool {
        guard shouldResume, quickDictationEnabled else { return false }
        return appIsForeground || wasReadyWhenInterrupted
    }
}

/// What to tell the user about a recording that is digital silence.
///
/// A microphone another app has taken delivers exact zeros, which is why this
/// case existed. But so does a capture that was finished before any audio
/// arrived, or a muted input, and blaming "another app or a call" for those
/// sends people looking for a culprit that is not there. The call is named only
/// when this app actually saw its audio interrupted or its input disappear.
enum SilentCapturePolicy {
    static func failureMessage(audioWasInterrupted: Bool) -> String {
        if audioWasInterrupted {
            return "Another app or a call was using the microphone, so only "
                + "silence was recorded. Try again once it has finished."
        }
        return "No speech was heard. Check that the microphone isn't muted, "
            + "then try again."
    }
}
