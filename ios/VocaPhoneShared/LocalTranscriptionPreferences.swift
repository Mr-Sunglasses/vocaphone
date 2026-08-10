import Foundation

/// The local engine preference is shared by the app and keyboard through the
/// App Group. The keyboard never loads a model: it only reads this switch when
/// it creates a session, while the containing app performs the inference.
enum LocalTranscriptionPreferences {
    static let enabledKey = "localTranscriptionEnabled"
    static let modelKey = "localTranscriptionModel"

    nonisolated(unsafe) private static let defaults = UserDefaults(
        suiteName: AppConfiguration.appGroupIdentifier
    )

    static var enabled: Bool {
        get { defaults?.bool(forKey: enabledKey) ?? false }
        set { defaults?.set(newValue, forKey: enabledKey) }
    }

    static var modelIdentifier: String? {
        get { defaults?.string(forKey: modelKey) }
        set { defaults?.set(newValue, forKey: modelKey) }
    }
}
