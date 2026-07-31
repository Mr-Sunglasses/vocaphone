import Foundation

enum AppConfiguration {
    static let appGroupIdentifier = "group.com.example.localflow"
    static let urlScheme = "localflow"
    static let maximumRecordingSeconds: TimeInterval = 120
    static let quickDictationWindowSeconds: TimeInterval = 10 * 60
    static let quickDictationLaunchFallbackSeconds: TimeInterval = 1.5
}
