import Foundation

/// The local engine preference is shared by the app and keyboard through the
/// App Group. The keyboard never loads a model: it only reads this switch when
/// it creates a session, while the containing app performs the inference.
enum LocalTranscriptionPreferences {
    static let enabledKey = "localTranscriptionEnabled"
    static let modelKey = "localTranscriptionModel"
    static let qualityKey = "localTranscriptionQuality"
    static let vocabularyKey = "localTranscriptionVocabulary"
    static let transcriptRetentionKey = "transcriptRetention"

    nonisolated(unsafe) private static let defaults = UserDefaults(
        suiteName: AppConfiguration.appGroupIdentifier
    )

    static var enabled: Bool {
        get { defaults?.bool(forKey: enabledKey) ?? false }
        set { defaults?.set(newValue, forKey: enabledKey) }
    }

    /// Setting it also clears `retiredModelReplacement`: every write except the
    /// migration's is a model the person chose, and "Your voice model was
    /// updated" would be a false explanation if that model later went missing.
    /// The migration writes its marker straight after.
    static var modelIdentifier: String? {
        get { defaults?.string(forKey: modelKey) }
        set {
            defaults?.set(newValue, forKey: modelKey)
            defaults?.removeObject(forKey: retiredModelReplacementKey)
        }
    }

    static let retiredModelReplacementKey = "localTranscriptionRetiredModelReplacement"

    /// The model the retired-model migration moved this iPhone onto, or nil.
    ///
    /// The picker offers it back as a one-tap download while it is still the
    /// selection and not on this iPhone, because the migration can change the
    /// setting but cannot fetch hundreds of megabytes on its own.
    static var retiredModelReplacement: String? {
        get { defaults?.string(forKey: retiredModelReplacementKey) }
        set { defaults?.set(newValue, forKey: retiredModelReplacementKey) }
    }

    /// The selection is a replacement the migration chose, not the user.
    static var selectionIsRetiredModelReplacement: Bool {
        guard enabled, let id = modelIdentifier else { return false }
        return id == retiredModelReplacement
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
    /// How long finished transcripts are kept on this iPhone.
    static var transcriptRetention: TranscriptRetention {
        get { TranscriptRetention.fromStored(defaults?.string(forKey: transcriptRetentionKey)) }
        set { defaults?.set(newValue.rawValue, forKey: transcriptRetentionKey) }
    }

    static var customVocabulary: String {
        get { defaults?.string(forKey: vocabularyKey) ?? "" }
        set { defaults?.set(newValue, forKey: vocabularyKey) }
    }
}
