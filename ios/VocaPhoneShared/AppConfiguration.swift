import Foundation

enum AppConfiguration {
    static let appGroupIdentifier = "group.com.vocahq.vocaphone"
    /// Must match `VocaPhoneKeyboard`'s `PRODUCT_BUNDLE_IDENTIFIER` in
    /// `project.yml`. Only used to spot the keyboard in the user's enabled
    /// list, so drift degrades guided setup rather than breaking dictation.
    static let keyboardBundleIdentifier = "com.vocahq.vocaphone.keyboard"
    static let urlScheme = "vocaphone"
    /// The manual route to the Full Access switch, written once because the app
    /// and the keyboard both have to give it and they must not disagree.
    ///
    /// iOS exposes no URL that opens this pane — `openSettingsURLString` lands
    /// in vocaphone's own settings, which does not contain the switch — so these
    /// words are the whole recovery path, and calling anything else a "deep
    /// link" to it would be a promise the system cannot keep.
    static let fullAccessSettingsPath =
        "Settings › General › Keyboard › Keyboards › vocaphone › Allow Full Access."

    /// The same instruction, front-loaded for the keyboard's two-line bar.
    ///
    /// The full path does not fit there and truncates mid-phrase — "… › Allow
    /// Full A…" — which drops the one part the reader has to act on. Naming the
    /// switch first means a truncation costs the tail of the path, which the
    /// containing app spells out in full under Privacy and permissions.
    static let fullAccessKeyboardHint =
        "Turn on Allow Full Access under Settings › General › Keyboard."
    static let maximumRecordingSeconds: TimeInterval = 120
    static let quickDictationWindowSeconds: TimeInterval = 10 * 60
    /// How long the keyboard waits for an unclaimed Quick Dictation request
    /// before falling back to opening vocaphone.
    static let quickDictationLaunchFallbackSeconds: TimeInterval = 1.5
    /// How long it keeps waiting once the containing app has claimed the
    /// request. Warming the microphone graph can take several seconds — a first
    /// on-device model load, or another app still releasing the input — and
    /// switching apps on a dictation that is about to start anyway is the more
    /// disruptive failure.
    static let quickDictationClaimedLaunchDeadlineSeconds: TimeInterval = 8
}
