import Foundation

/// The one-time offer to turn Quick Dictation back on, shown to the people an
/// older build turned it off for.
///
/// Until this release the Live Activity's stop button wrote the durable
/// preference, so a single tap on a control with no undo left Quick Dictation
/// off until the user found the switch in Settings. Those installs carry a
/// stored `false` that is indistinguishable from a deliberate choice, so
/// nothing here flips it back: re-arming somebody's microphone on their behalf
/// would be a worse bug than the one being fixed. The app asks instead, once,
/// and takes either answer as final.
struct QuickDictationRecoveryOffer: Equatable {
    var title: String
    var detail: String
    var confirm: String
    var dismiss: String

    /// `nil` whenever there is nothing to ask: the offer was already answered,
    /// this install was never affected, or Quick Dictation is on — including
    /// when the user turned it on themselves in Settings before reaching Home.
    static func make(isPending: Bool, isEnabled: Bool) -> QuickDictationRecoveryOffer? {
        guard isPending, !isEnabled else { return nil }
        return QuickDictationRecoveryOffer(
            title: "Quick Dictation is off",
            // Names what happened, because the people seeing this card mostly
            // do not believe they ever turned the feature off.
            detail: "Stopping it from the Dynamic Island used to switch it off for "
                + "good — it now only pauses until you reopen vocaphone. Turn it back "
                + "on to dictate without leaving the app you are in.",
            confirm: "Turn it back on",
            dismiss: "Not now"
        )
    }
}
