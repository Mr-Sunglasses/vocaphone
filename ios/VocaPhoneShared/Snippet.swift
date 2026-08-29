import Foundation

/// A short trigger the user dictates that expands into longer text — a
/// signature, an address, a phrase said often enough to be worth saying
/// shorter. Persisted as JSON in the App Group so the app's settings and the
/// funnel that finishes a transcript agree on the same list.
struct Snippet: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var trigger: String
    var expansion: String

    init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

enum SnippetStore {
    static let key = "vocaphone.snippets"

    nonisolated(unsafe) static let defaults = UserDefaults(
        suiteName: AppConfiguration.appGroupIdentifier
    )

    static var snippets: [Snippet] {
        get {
            guard let data = defaults?.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([Snippet].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults?.set(data, forKey: key)
        }
    }
}
