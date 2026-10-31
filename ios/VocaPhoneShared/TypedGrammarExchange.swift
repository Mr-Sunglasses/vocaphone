import Foundation

/// One "Check grammar" question from the keyboard to the containing app.
///
/// The keyboard extension cannot hold the grammar model: it runs near its
/// memory limit already, and the model and ONNX Runtime would take it past.
/// The app can, and while Quick Dictation keeps it running it answers. The
/// sentence travels through one small file in the App Group, which the app
/// deletes as it reads it; the answer comes back the same way and the keyboard
/// deletes it in turn. Nothing here leaves the phone, and nothing is kept.
struct TypedGrammarRequest: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    /// Older than this, nobody is waiting for the answer: the user has typed
    /// on, and the keyboard has asked again or stopped asking.
    static let maximumAge: TimeInterval = 5

    let schemaVersion: Int
    let id: UUID
    /// The sentences to check, as `TypedGrammar.region(before:startKnown:)`
    /// chose them. Never more than `TypedGrammar.maxRegion` characters.
    let text: String
    /// Words the model may not change: the user's own vocabulary, learned
    /// words and snippet triggers, lowercased.
    let keep: [String]
    let createdAt: Date

    init(id: UUID = UUID(), text: String, keep: [String], createdAt: Date = Date()) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.text = text
        self.keep = keep
        self.createdAt = createdAt
    }

    func isFresh(at date: Date = Date()) -> Bool {
        schemaVersion == Self.schemaVersion
            && date.timeIntervalSince(createdAt) <= Self.maximumAge
            && date.timeIntervalSince(createdAt) >= -1
    }
}

/// The app's answer to a `TypedGrammarRequest`.
struct TypedGrammarAnswer: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    /// The request this answers. The keyboard drops any other.
    let id: UUID
    /// The model's text, or `nil` when the app could not check it: the
    /// setting is off there, the model is missing or still loading.
    let corrected: String?

    init(id: UUID, corrected: String?) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.corrected = corrected
    }
}
