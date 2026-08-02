import Foundation

enum WritingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case formal
    case casual
    case veryCasual = "very_casual"
    case excited

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very Casual"
        case .excited: "Excited"
        }
    }

    var detail: String {
        switch self {
        case .formal: "Sentence capitalization with complete punctuation."
        case .casual: "Sentence capitalization with lighter punctuation."
        case .veryCasual: "Lowercase with punctuation removed."
        case .excited: "Sentence capitalization with expressive punctuation."
        }
    }

    var symbolName: String {
        switch self {
        case .formal: "textformat"
        case .casual: "text.bubble"
        case .veryCasual: "textformat.abc"
        case .excited: "sparkles"
        }
    }
}

enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case english = "en"
    case spanish = "es"
    case arabic = "ar"
    case japanese = "ja"
    case korean = "ko"
    case mandarinChinese = "zh"
    case ukrainian = "uk"
    case vietnamese = "vi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .english: "English"
        case .spanish: "Spanish"
        case .arabic: "Arabic"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .mandarinChinese: "Mandarin Chinese"
        case .ukrainian: "Ukrainian"
        case .vietnamese: "Vietnamese"
        }
    }

    var shortLabel: String {
        switch self {
        case .automatic: "Auto"
        case .english: "EN"
        case .spanish: "ES"
        case .arabic: "AR"
        case .japanese: "JA"
        case .korean: "KO"
        case .mandarinChinese: "ZH"
        case .ukrainian: "UK"
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
    static let containingAppForegroundKey = "containingAppForeground"

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
    /// keyboard only runs inside the frontmost app, so finding Local Flow in the
    /// foreground tells the keyboard that Local Flow is its own host.
    static var containingAppIsForeground: Bool {
        get { defaults?.bool(forKey: containingAppForegroundKey) ?? false }
        set { defaults?.set(newValue, forKey: containingAppForegroundKey) }
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
