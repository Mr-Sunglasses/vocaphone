import Foundation

enum AppConfiguration {
    static let appGroupIdentifier = "group.com.vocahq.vocaphone"
    /// Must match `VocaPhoneKeyboard`'s `PRODUCT_BUNDLE_IDENTIFIER` in
    /// `project.yml`. Only used to spot the keyboard in the user's enabled
    /// list, so drift degrades guided setup rather than breaking dictation.
    static let keyboardBundleIdentifier = "com.vocahq.vocaphone.keyboard"
    static let urlScheme = "vocaphone"
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
