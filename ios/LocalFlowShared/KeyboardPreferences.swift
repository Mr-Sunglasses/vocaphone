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

enum KeyboardPreferences {
    static let autoInsertKey = "autoInsertTranscripts"
    static let quickDictationKey = "quickDictationEnabled"
    static let writingStyleKey = "writingStyle"

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
}
