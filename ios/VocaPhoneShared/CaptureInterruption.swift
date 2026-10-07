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

/// What the containing app remembers about Quick Dictation across one audio
/// interruption, from the moment it begins to the moment it ends.
///
/// The interruption itself tears standby down, so whether a window was running
/// has to be read before that and carried to the end. A second interruption
/// that begins before the first has ended — a call, then Siri — keeps the first
/// answer: by then standby is already gone, and it was gone because of the
/// call, not because the user ended it.
///
/// iOS does not promise an end for every beginning. Anything that settles the
/// window in the meantime — arming it again, or the user pausing, closing or
/// switching it off — forgets the interruption, so a later, unrelated one can
/// never bring back a window nobody had.
struct QuickDictationInterruption: Equatable {
    private(set) var wasRunning = false

    /// - Parameter running: standby or a dictation was live when the audio
    ///   session was taken.
    mutating func began(running: Bool) {
        wasRunning = wasRunning || running
    }

    /// Whether to arm standby again now that the interruption is over. Either
    /// way the interruption is over and forgotten.
    mutating func ended(
        shouldResume: Bool,
        quickDictationArmable: Bool,
        appIsForeground: Bool
    ) -> Bool {
        defer { wasRunning = false }
        return QuickDictationInterruptionPolicy.shouldRearm(
            shouldResume: shouldResume,
            quickDictationEnabled: quickDictationArmable,
            appIsForeground: appIsForeground,
            wasReadyWhenInterrupted: wasRunning
        )
    }

    /// The window was settled some other way: armed again, or ended by the user.
    mutating func forget() {
        wasRunning = false
    }
}

/// What to tell the user about a recording that is digital silence.
///
/// A microphone another app has taken delivers exact zeros, which is why this
/// case existed. But so does a capture that was finished before any audio
/// arrived, or a muted input, and stating "another app or a call" as fact for
/// those sends people looking for a culprit that is not there. The call is
/// named as the cause only when this app actually saw its audio interrupted or
/// its input disappear.
///
/// Without that, another app is still a candidate rather than ruled out: the
/// session mixes with others, and iOS can hand a mixing app zeros when a
/// foreground app starts recording, without posting an interruption. So the
/// copy lists it among the things to check instead of dropping it.
enum SilentCapturePolicy {
    static func failureMessage(audioWasInterrupted: Bool) -> String {
        if audioWasInterrupted {
            return "Another app or a call was using the microphone, so only "
                + "silence was recorded. Try again once it has finished."
        }
        return "No speech was heard. Check that the microphone isn't muted "
            + "or in use by another app, then try again."
    }
}
