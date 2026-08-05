import Foundation

enum AppConfiguration {
    static let appGroupIdentifier = "group.com.example.localflow"
    /// Must match `LocalFlowKeyboard`'s `PRODUCT_BUNDLE_IDENTIFIER` in
    /// `project.yml`. Only used to spot the keyboard in the user's enabled
    /// list, so drift degrades guided setup rather than breaking dictation.
    static let keyboardBundleIdentifier = "com.example.localflow.keyboard"
    static let urlScheme = "localflow"
    static let maximumRecordingSeconds: TimeInterval = 120
    static let quickDictationWindowSeconds: TimeInterval = 10 * 60
    static let quickDictationLaunchFallbackSeconds: TimeInterval = 1.5
}
