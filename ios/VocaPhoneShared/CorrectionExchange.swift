import Foundation

/// Spellings the keyboard learned from one dictation, on their way to the app.
///
/// The keyboard extension cannot write the app's Dictionary itself, and
/// should not: what to suggest, add or forget is the app's to decide. Each
/// batch is one small file in the App Group, `learned-corrections/`, which the
/// app reads and deletes as it comes to the foreground. It holds the
/// "heard → corrected" pairs and nothing else — no text from the field.
struct LearnedCorrectionBatch: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    /// Batches waiting at once; the oldest go first, so a keyboard used for
    /// weeks without opening the app cannot fill the container.
    static let maximumWaiting = 20
    /// Pairs in one batch: the learner finds at most three per dictation.
    static let maximumCorrections = 3

    let schemaVersion: Int
    let id: UUID
    let corrections: [LearnedCorrection]
    let createdAt: Date

    init(id: UUID = UUID(), corrections: [LearnedCorrection], createdAt: Date = Date()) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.corrections = Array(corrections.prefix(Self.maximumCorrections))
        self.createdAt = createdAt
    }
}

extension SharedStore {
    /// Leaves a batch for the app. Its own file, so the keyboard never reads
    /// back or rewrites one the app may be taking.
    func saveLearnedCorrections(_ batch: LearnedCorrectionBatch) throws {
        let directory = try learnedCorrectionsDirectory()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let name = "\(Int(batch.createdAt.timeIntervalSince1970 * 1000))-\(batch.id.uuidString.lowercased()).json"
        try encoder.encode(batch).write(to: directory.appendingPathComponent(name), options: .atomic)
        trimLearnedCorrections(in: directory)
    }

    /// Every waiting batch, oldest first, each deleted as it is read. A file
    /// is claimed by renaming it first, which is atomic, so a batch the
    /// keyboard saves meanwhile is never deleted unread. Batches from another
    /// schema are dropped.
    func takeLearnedCorrections() -> [LearnedCorrectionBatch] {
        guard let directory = try? learnedCorrectionsDirectory() else { return [] }
        let fileManager = FileManager.default
        let names = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var batches: [LearnedCorrectionBatch] = []
        for name in names where name.hasSuffix(".json") {
            let file = directory.appendingPathComponent(name)
            let claimed = directory.appendingPathComponent("\(name).\(UUID().uuidString).taking")
            guard (try? fileManager.moveItem(at: file, to: claimed)) != nil else { continue }
            defer { try? fileManager.removeItem(at: claimed) }
            guard let data = try? Data(contentsOf: claimed),
                  let batch = try? decoder.decode(LearnedCorrectionBatch.self, from: data),
                  batch.schemaVersion == LearnedCorrectionBatch.schemaVersion
            else { continue }
            batches.append(batch)
        }
        // A claim a process never finished, ended mid-read.
        for name in names where name.hasSuffix(".taking") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        return batches
    }

    /// Removes every waiting batch: learning was turned off.
    func removeLearnedCorrections() {
        guard let directory = try? learnedCorrectionsDirectory() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func learnedCorrectionsDirectory() throws -> URL {
        try rootDirectory().appendingPathComponent("learned-corrections", isDirectory: true)
    }

    private func trimLearnedCorrections(in directory: URL) {
        let fileManager = FileManager.default
        let names = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .sorted()
        guard names.count > LearnedCorrectionBatch.maximumWaiting else { return }
        for name in names.prefix(names.count - LearnedCorrectionBatch.maximumWaiting) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// "Learn from my corrections": the switch, shared by the app and the
/// keyboard through the App Group, and the suggestions the app keeps.
///
/// Only "heard → corrected" pairs are stored, and only by the app.
enum CorrectionLearningPreferences {
    static let enabledKey = "learnFromCorrections"
    static let suggestionsKey = "correctionSuggestions"
    static let dismissedKey = "dismissedCorrectionSuggestions"

    nonisolated(unsafe) private static let defaults = UserDefaults(
        suiteName: AppConfiguration.appGroupIdentifier
    )

    /// Posted, in this process, whenever the suggestions or dismissals
    /// change, so a Suggested screen left open picks up what the app collects
    /// as it comes forward, and what it adds without asking.
    static let didChange = Notification.Name("VocaPhoneCorrectionSuggestionsDidChange")

    private static func changed() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// On unless the user turned it off.
    static var enabled: Bool {
        get { defaults?.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults?.set(newValue, forKey: enabledKey) }
    }

    /// Newest first.
    static var suggestions: [CorrectionSuggestion] {
        get { CorrectionSuggestion.decode(defaults?.data(forKey: suggestionsKey)) }
        set {
            defaults?.set(CorrectionSuggestion.encode(newValue), forKey: suggestionsKey)
            changed()
        }
    }

    static var dismissed: [String] {
        get { defaults?.stringArray(forKey: dismissedKey) ?? [] }
        set {
            defaults?.set(newValue, forKey: dismissedKey)
            changed()
        }
    }

    /// Takes what the keyboard left and counts it in: suggested, or added
    /// when due (`CorrectionSuggestions`). Run as the app comes forward.
    /// Returns how many fixes arrived.
    @discardableResult
    static func collectFromKeyboard(store: SharedStore = .shared, now: Date = Date()) -> Int {
        let batches = store.takeLearnedCorrections()
        guard enabled else { return 0 }
        let found = batches.flatMap(\.corrections)
        guard !found.isEmpty else { return 0 }
        receive(found, now: now)
        return found.count
    }

    /// `found` counted into the suggestions; fixes made often enough are
    /// added to the custom words and replacements at once.
    static func receive(_ found: [LearnedCorrection], now: Date = Date()) {
        let replacements = LocalTranscriptionPreferences.replacements
        let vocabulary = CustomVocabulary.terms(LocalTranscriptionPreferences.customVocabulary)
        let received = CorrectionSuggestions.receive(
            found, into: suggestions, dismissed: dismissed, now: now
        ) { heard, corrected in
            CorrectionSuggestions.isListed(
                heard: heard, corrected: corrected, replacements: replacements, vocabulary: vocabulary
            )
        }
        suggestions = received.suggestions
        for suggestion in received.added { learn(suggestion) }
    }

    /// Add: the word and, when due, a replacement.
    static func accept(_ suggestion: CorrectionSuggestion) {
        suggestions = suggestions.filter { $0.id != suggestion.id }
        learn(suggestion)
    }

    /// Dismiss: gone, and not suggested again.
    static func dismiss(_ suggestion: CorrectionSuggestion) {
        suggestions = suggestions.filter { $0.id != suggestion.id }
        dismissed = CorrectionSuggestions.dismissing(suggestion.id, from: dismissed)
    }

    /// Forgets every suggestion and dismissal, and anything still waiting
    /// from the keyboard. Words already added stay in their lists.
    static func clear(store: SharedStore = .shared) {
        defaults?.removeObject(forKey: suggestionsKey)
        defaults?.removeObject(forKey: dismissedKey)
        store.removeLearnedCorrections()
        changed()
    }

    private static func learn(_ suggestion: CorrectionSuggestion) {
        let learned = CorrectionSuggestions.learn(suggestion, replacements: LocalTranscriptionPreferences.replacements)
        if learned.replacements != LocalTranscriptionPreferences.replacements {
            LocalTranscriptionPreferences.replacements = learned.replacements
        }
        let vocabulary = LocalTranscriptionPreferences.customVocabulary
        let updated = CorrectionSuggestions.vocabulary(vocabulary, adding: learned.term)
        if updated != vocabulary { LocalTranscriptionPreferences.customVocabulary = updated }
    }
}
