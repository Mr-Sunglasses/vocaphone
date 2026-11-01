import Foundation

/// One Writing check question from the keyboard to the containing app: the
/// sentences the grammar model has not seen yet.
///
/// The keyboard extension cannot hold the grammar model: it runs near its
/// memory limit already, and the model and ONNX Runtime would take it past.
/// The app can, and while Quick Dictation keeps it running it answers. The
/// rules run in the keyboard itself, so this is only ever about the model.
/// The sentences travel through one small file in the App Group, which the
/// app deletes as it reads it; the answer comes back the same way and the
/// keyboard deletes it in turn. Nothing here leaves the phone, and nothing is
/// kept.
struct TypedGrammarRequest: Codable, Equatable, Sendable {
    /// 2: a batch of sentences rather than one region.
    static let schemaVersion = 2
    /// Older than this, nobody is waiting for the answer: the user has typed
    /// on, and the keyboard has asked again or stopped asking.
    static let maximumAge: TimeInterval = 5
    /// At most this many sentences per question; the rest wait for the next.
    static let maximumSentences = 12

    let schemaVersion: Int
    let id: UUID
    /// The sentences to correct, each as the keyboard split it.
    let sentences: [String]
    /// Words the model may not change: the user's own vocabulary, learned
    /// words and snippet triggers, lowercased.
    let keep: [String]
    let createdAt: Date
    /// The user asked for this check (the Writing check button): the model
    /// offers more, since each edit is shown before it is made. Absent is
    /// false, so a question from before this field still reads.
    let thorough: Bool?

    init(
        id: UUID = UUID(), sentences: [String], keep: [String], createdAt: Date = Date(), thorough: Bool = false
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.sentences = Array(sentences.prefix(Self.maximumSentences))
        self.keep = keep
        self.createdAt = createdAt
        self.thorough = thorough
    }

    func isFresh(at date: Date = Date()) -> Bool {
        schemaVersion == Self.schemaVersion
            && date.timeIntervalSince(createdAt) <= Self.maximumAge
            && date.timeIntervalSince(createdAt) >= -1
    }
}

/// The app's answer to a `TypedGrammarRequest`.
struct TypedGrammarAnswer: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    /// The request this answers. The keyboard drops any other.
    let id: UUID
    /// The model's text for each sentence, in order, or `nil` where the app
    /// could not check it: the setting is off there, the model is missing or
    /// still loading.
    let corrected: [String?]

    init(id: UUID, corrected: [String?]) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.corrected = corrected
    }
}

/// Text the keyboard hands to the app's Writing check screen.
struct WritingDraft: Codable, Equatable, Sendable {
    /// Older than this, the user has moved on; the app opens empty.
    static let maximumAge: TimeInterval = 60
    let text: String
    let createdAt: Date
}
