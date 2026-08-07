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
    static let quickDictationLaunchFallbackSeconds: TimeInterval = 1.5
}
