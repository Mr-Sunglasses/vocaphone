import Foundation

/// Presentation only. No style adds, removes or substitutes a word, and
/// numbers, times, addresses and contractions are always left as the model
/// transcribed them.
enum WritingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case raw
    case clean
    case formal
    case casual
    case veryCasual = "very_casual"
    case excited

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw: "Raw"
        case .clean: "Clean"
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very Casual"
        case .excited: "Excited"
        }
    }

    var detail: String {
        switch self {
        case .raw:
            "Exactly what the model returned, with nothing changed."
        case .clean:
            "Spacing tidied and a closing full stop. Capitalization untouched."
        case .formal:
            "Sentence capitalization and a closing full stop."
        case .casual:
            "Sentences kept, but no closing full stop."
        case .veryCasual:
            "All lowercase, sentences joined with commas."
        case .excited:
            "Every statement ends with an exclamation mark."
        }
    }

    /// A short worked example, so the choice is obvious before dictating.
    var example: String {
        switch self {
        case .raw: "I don't think it's ready. It cost $1,200."
        case .clean: "I don't think it's ready. It cost $1,200."
        case .formal: "I don't think it's ready. It cost $1,200."
        case .casual: "I don't think it's ready. It cost $1,200"
        case .veryCasual: "i don't think it's ready, it cost $1,200"
        case .excited: "I don't think it's ready! It cost $1,200!"
        }
    }

    var symbolName: String {
        switch self {
        case .raw: "doc.plaintext"
        case .clean: "wand.and.stars"
        case .formal: "textformat"
        case .casual: "text.bubble"
        case .veryCasual: "textformat.abc"
        case .excited: "sparkles"
        }
    }
}

enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case arabic = "ar"
    case assamese = "as"
    case bengali = "bn"
    case dutch = "nl"
    case english = "en"
    case french = "fr"
    case german = "de"
    case gujarati = "gu"
    case hindi = "hi"
    case italian = "it"
    case japanese = "ja"
    case kannada = "kn"
    case korean = "ko"
    case malayalam = "ml"
    case mandarinChinese = "zh"
    case marathi = "mr"
    case nepali = "ne"
    case polish = "pl"
    case portuguese = "pt"
    case punjabi = "pa"
    case russian = "ru"
    case spanish = "es"
    case tamil = "ta"
    case telugu = "te"
    case ukrainian = "uk"
    case urdu = "ur"
    case vietnamese = "vi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .arabic: "Arabic"
        case .assamese: "Assamese"
        case .bengali: "Bengali"
        case .dutch: "Dutch"
        case .english: "English"
        case .french: "French"
        case .german: "German"
        case .gujarati: "Gujarati"
        case .hindi: "Hindi"
        case .italian: "Italian"
        case .japanese: "Japanese"
        case .kannada: "Kannada"
        case .korean: "Korean"
        case .malayalam: "Malayalam"
        case .mandarinChinese: "Mandarin Chinese"
        case .marathi: "Marathi"
        case .nepali: "Nepali"
        case .polish: "Polish"
        case .portuguese: "Portuguese"
        case .punjabi: "Punjabi"
        case .russian: "Russian"
        case .spanish: "Spanish"
        case .tamil: "Tamil"
        case .telugu: "Telugu"
        case .ukrainian: "Ukrainian"
        case .urdu: "Urdu"
        case .vietnamese: "Vietnamese"
        }
    }

    var shortLabel: String {
        switch self {
        case .automatic: "Auto"
        case .arabic: "AR"
        case .assamese: "AS"
        case .bengali: "BN"
        case .dutch: "NL"
        case .english: "EN"
        case .french: "FR"
        case .german: "DE"
        case .gujarati: "GU"
        case .hindi: "HI"
        case .italian: "IT"
        case .japanese: "JA"
        case .kannada: "KN"
        case .korean: "KO"
        case .malayalam: "ML"
        case .mandarinChinese: "ZH"
        case .marathi: "MR"
        case .nepali: "NE"
        case .polish: "PL"
        case .portuguese: "PT"
        case .punjabi: "PA"
        case .russian: "RU"
        case .spanish: "ES"
        case .tamil: "TA"
        case .telugu: "TE"
        case .ukrainian: "UK"
        case .urdu: "UR"
        case .vietnamese: "VI"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Uses the language of the model selected on your gateway."
        default:
            "Requires a matching multilingual or \(displayName) model on your gateway."
        }
    }
}

enum MicrophonePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case iPhone = "iphone"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .iPhone: "iPhone Microphone"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "iOS chooses the input and may use an AirPods microphone when connected."
        case .iPhone:
            "Always request the microphone built into this iPhone."
        }
    }
}

enum KeyboardPreferences {
    static let autoInsertKey = "autoInsertTranscripts"
    static let quickDictationKey = "quickDictationEnabled"
    static let writingStyleKey = "writingStyle"
    static let transcriptionLanguageKey = "transcriptionLanguage"
    static let microphonePreferenceKey = "microphonePreference"
    static let recordingSoundsKey = "recordingSoundsEnabled"
    static let containingAppForegroundKey = "containingAppForeground"
    static let setupCompletedKey = "setupCompleted"
    static let firstDictationKey = "hasCompletedFirstDictation"
    static let modelLanguagesKey = "gatewayModelLanguages"
    static let modelDetectsLanguageKey = "gatewayModelDetectsLanguage"
    static let recentLanguagesKey = "recentTranscriptionLanguages"

    nonisolated(unsafe) static let defaults = UserDefaults(
        suiteName: AppConfiguration.appGroupIdentifier
    )

    static var autoInsertTranscripts: Bool {
        get {
            guard let defaults else { return true }
            guard defaults.object(forKey: autoInsertKey) != nil else { return true }
            return defaults.bool(forKey: autoInsertKey)
        }
        set {
            defaults?.set(newValue, forKey: autoInsertKey)
        }
    }

    static var quickDictationEnabled: Bool {
        get {
            guard let defaults else { return true }
            guard defaults.object(forKey: quickDictationKey) != nil else { return true }
            return defaults.bool(forKey: quickDictationKey)
        }
        set {
            defaults?.set(newValue, forKey: quickDictationKey)
        }
    }

    static var recordingSoundsEnabled: Bool {
        get { defaults?.bool(forKey: recordingSoundsKey) ?? false }
        set { defaults?.set(newValue, forKey: recordingSoundsKey) }
    }

    static var writingStyle: WritingStyle {
        get {
            guard let rawValue = defaults?.string(forKey: writingStyleKey),
                  let style = WritingStyle(rawValue: rawValue)
            else { return .casual }
            return style
        }
        set {
            defaults?.set(newValue.rawValue, forKey: writingStyleKey)
        }
    }

    /// Languages picked recently, most recent first. Shared through the App Group
    /// so the keyboard's short menu and the app agree on what to surface, and
    /// capped because the point is to keep the keyboard menu to a glance.
    static let recentLanguageLimit = 3

    static var recentTranscriptionLanguages: [TranscriptionLanguage] {
        get {
            (defaults?.stringArray(forKey: recentLanguagesKey) ?? [])
                .compactMap(TranscriptionLanguage.init(rawValue:))
        }
        set {
            defaults?.set(newValue.map(\.rawValue), forKey: recentLanguagesKey)
        }
    }

    /// Records a pick. Automatic is excluded: it is always shown first anyway, so
    /// listing it again would spend one of three scarce slots on a duplicate.
    static func noteTranscriptionLanguageUse(_ language: TranscriptionLanguage) {
        guard language != .automatic else { return }
        var recents = recentTranscriptionLanguages.filter { $0 != language }
        recents.insert(language, at: 0)
        recentTranscriptionLanguages = Array(recents.prefix(recentLanguageLimit))
    }

    /// What the gateway's loaded model can be asked for, written by the app after
    /// each health check. Stored in the App Group so the keyboard's own language
    /// menu reaches the same conclusion as the containing app rather than
    /// offering choices the app has already ruled out.
    static var modelLanguages: Set<String> {
        get { Set(defaults?.stringArray(forKey: modelLanguagesKey) ?? []) }
        set { defaults?.set(Array(newValue).sorted(), forKey: modelLanguagesKey) }
    }

    static var modelDetectsLanguage: Bool {
        get { defaults?.bool(forKey: modelDetectsLanguageKey) ?? false }
        set { defaults?.set(newValue, forKey: modelDetectsLanguageKey) }
    }

    /// The language claim that governs the picker.
    ///
    /// With on-device transcription on, the gateway's last engine report is
    /// irrelevant and often wrong in both directions: it can hide languages the
    /// local model supports, or offer ones it does not.
    private static var activeLocalModel: LocalModelDescriptor? {
        guard LocalTranscriptionPreferences.enabled else { return nil }
        return LocalModelCatalog.descriptor(for: LocalTranscriptionPreferences.modelIdentifier)
    }

    static var activeModelLanguages: Set<String> {
        activeLocalModel?.languageCodes ?? modelLanguages
    }

    static var activeModelDetectsLanguage: Bool {
        activeLocalModel?.detectsLanguageAutomatically ?? modelDetectsLanguage
    }

    /// The language to actually dictate in, after discarding a stored choice the
    /// current model cannot honour.
    static var effectiveTranscriptionLanguage: TranscriptionLanguage {
        ModelLanguageSupport.resolve(
            transcriptionLanguage,
            modelLanguages: activeModelLanguages,
            detectsLanguageAutomatically: activeModelDetectsLanguage
        )
    }

    static var transcriptionLanguage: TranscriptionLanguage {
        get {
            guard let rawValue = defaults?.string(forKey: transcriptionLanguageKey),
                  let language = TranscriptionLanguage(rawValue: rawValue)
            else { return .automatic }
            return language
        }
        set {
            defaults?.set(newValue.rawValue, forKey: transcriptionLanguageKey)
        }
    }

    /// Maintained by the containing app across foreground transitions. A custom
    /// keyboard only runs inside the frontmost app, so finding vocaphone in the
    /// foreground tells the keyboard that vocaphone is its own host.
    static var containingAppIsForeground: Bool {
        get { defaults?.bool(forKey: containingAppForegroundKey) ?? false }
        set { defaults?.set(newValue, forKey: containingAppForegroundKey) }
    }

    /// Set when the user leaves guided setup, so it opens once rather than on
    /// every launch. Whether setup is actually finished is re-derived from the
    /// system each time; this only records that the screen has been seen.
    static var setupCompleted: Bool {
        get { defaults?.bool(forKey: setupCompletedKey) ?? false }
        set { defaults?.set(newValue, forKey: setupCompletedKey) }
    }

    /// One transcript has made it back from the gateway, which is the only
    /// proof that recording, upload, and transcription all work together.
    static var hasCompletedFirstDictation: Bool {
        get { defaults?.bool(forKey: firstDictationKey) ?? false }
        set { defaults?.set(newValue, forKey: firstDictationKey) }
    }

    static var microphonePreference: MicrophonePreference {
        get {
            guard let rawValue = defaults?.string(forKey: microphonePreferenceKey),
                  let preference = MicrophonePreference(rawValue: rawValue)
            else { return .automatic }
            return preference
        }
        set {
            defaults?.set(newValue.rawValue, forKey: microphonePreferenceKey)
        }
    }
}
