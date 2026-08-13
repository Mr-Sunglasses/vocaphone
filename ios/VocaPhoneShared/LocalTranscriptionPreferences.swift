import Foundation

/// The local engine preference is shared by the app and keyboard through the
/// App Group. The keyboard never loads a model: it only reads this switch when
/// it creates a session, while the containing app performs the inference.
enum LocalTranscriptionPreferences {
    static let enabledKey = "localTranscriptionEnabled"
    static let modelKey = "localTranscriptionModel"
    static let qualityKey = "localTranscriptionQuality"
    static let vocabularyKey = "localTranscriptionVocabulary"

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

    /// How much decoding work the local engines may spend. Read at inference
    /// time rather than passed down, so a change takes effect on the next
    /// dictation without a session needing to carry it.
    static var quality: TranscriptionQuality {
        get { TranscriptionQuality.fromStored(defaults?.string(forKey: qualityKey)) }
        set { defaults?.set(newValue.rawValue, forKey: qualityKey) }
    }

    /// Names and jargon to bias an on-device Whisper model toward, exactly as
    /// the user typed them. `CustomVocabulary` does the parsing, so the text
    /// they see back is the text they wrote.
    static var customVocabulary: String {
        get { defaults?.string(forKey: vocabularyKey) ?? "" }
        set { defaults?.set(newValue, forKey: vocabularyKey) }
    }
}
