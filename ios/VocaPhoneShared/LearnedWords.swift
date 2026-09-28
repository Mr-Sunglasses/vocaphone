import Foundation

/// Words this user typed and kept.
///
/// A keyboard that never learns feels broken by the second day: it corrects the
/// same surname away every time, and the user gives up and turns autocorrect off.
///
/// Two rules make this safe rather than creepy:
///
/// 1. **Never `UITextChecker.learnWord(_:)`.** That writes into the user's
///    system-wide dictionary and changes behaviour in every other app on the
///    phone. A keyboard doing that silently is a bug whatever its intentions.
/// 2. **Nothing here is ever logged, exported, or listed.** The UI shows a
///    count and a reset button; the words themselves are not a feature.
///
/// Without Full Access there is no App Group, so the store degrades to memory
/// for the lifetime of the keyboard instance — and the Keyboard settings screen
/// says so rather than pretending it persisted.
struct LearnedWords: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var word: String
        var count: Int
        var lastUsedAt: Date
    }

    /// Enough for a vocabulary, small enough that reading the file is never
    /// something the user waits for.
    static let capacity = 2_000
    /// How many times an unknown word has to survive being typed before the
    /// keyboard concludes the user meant it.
    static let repetitionsBeforeLearning = 3

    private(set) var entries: [String: Entry] = [:]

    var count: Int { entries.count }

    var words: [String] { entries.values.map(\.word) }

    func contains(_ word: String) -> Bool { entries[Self.key(word)] != nil }

    /// Words starting with `prefix`, most used first — someone who has typed a
    /// name forty times should see it before one they typed twice.
    func completions(for prefix: String, limit: Int) -> [String] {
        guard !prefix.isEmpty, limit > 0 else { return [] }
        let lowered = Self.key(prefix)
        return entries.values
            .filter { Self.key($0.word).hasPrefix(lowered) && $0.word.count > prefix.count }
            .sorted {
                $0.count == $1.count ? $0.lastUsedAt > $1.lastUsedAt : $0.count > $1.count
            }
            .prefix(limit)
            .map(\.word)
    }

    /// Records one sighting, and reports whether the word is now learned.
    @discardableResult
    mutating func note(_ word: String, now: Date = Date()) -> Bool {
        let key = Self.key(word)
        guard !key.isEmpty else { return false }
        var entry = entries[key] ?? Entry(word: word, count: 0, lastUsedAt: now)
        entry.count += 1
        entry.lastUsedAt = now
        entries[key] = entry
        evictIfNeeded()
        return entry.count >= Self.repetitionsBeforeLearning
    }

    /// Learns a word outright — the user tapped their own spelling in the strip,
    /// which is as explicit as an instruction gets.
    mutating func learn(_ word: String, now: Date = Date()) {
        let key = Self.key(word)
        guard !key.isEmpty else { return }
        var entry = entries[key] ?? Entry(word: word, count: 0, lastUsedAt: now)
        entry.word = word
        entry.count = max(entry.count, Self.repetitionsBeforeLearning)
        entry.lastUsedAt = now
        entries[key] = entry
        evictIfNeeded()
    }

    mutating func removeAll() { entries.removeAll() }

    /// Least-recently-used eviction. Capacity is a memory bound, not a
    /// judgement about which words matter.
    private mutating func evictIfNeeded() {
        guard entries.count > Self.capacity else { return }
        let doomed = entries.values
            .sorted { $0.lastUsedAt < $1.lastUsedAt }
            .prefix(entries.count - Self.capacity)
        for entry in doomed { entries.removeValue(forKey: Self.key(entry.word)) }
    }

    private static func key(_ word: String) -> String { word.lowercased() }
}

/// Reads and writes ``LearnedWords`` in the App Group, and holds them in memory
/// when there is no App Group to write to.
///
/// Deliberately not part of `SharedStore`: that one carries dictation sessions,
/// which are transient and notify observers on every change. Learned words are
/// neither, and a Darwin notification per typed word would be absurd.
final class LearnedWordStore: @unchecked Sendable {
    static let fileName = "learned-words.json"

    private let fileURL: URL?
    private var cached: LearnedWords
    /// Guards `cached` and nothing else, so reading or changing the words
    /// never waits behind a file write.
    private let queue = DispatchQueue(label: "com.vocahq.vocaphone.learned-words")
    /// Where the file is written, behind the change and never in front of it.
    private let writer = DispatchQueue(label: "com.vocahq.vocaphone.learned-words.writer", qos: .utility)
    /// The newest words not yet on disk. A burst of learned words is written
    /// once, as whatever the last of them left, rather than once per word.
    private var pending: LearnedWords?

    /// `nil` container means no Full Access: everything still works, nothing
    /// survives the keyboard being torn down.
    var isPersistent: Bool { fileURL != nil }

    init(containerURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
    )) {
        fileURL = containerURL?.appendingPathComponent(Self.fileName)
        cached = Self.read(from: fileURL) ?? LearnedWords()
    }

    func snapshot() -> LearnedWords {
        queue.sync { cached }
    }

    /// Applies `change` at once and writes the file behind it.
    ///
    /// The write used to happen inside the same `sync`, so the keyboard's main
    /// thread encoded up to two thousand entries and wrote the file atomically
    /// before the next keystroke — once for every new word typed. The change
    /// is still immediate; the encoding and the write happen on their own
    /// queue, and ``flush(timeout:)`` is for the moment the keyboard leaves
    /// the screen.
    func update(_ change: @Sendable (inout LearnedWords) -> Void) {
        let needsWrite = queue.sync {
            change(&cached)
            let idle = pending == nil
            pending = cached
            return idle
        }
        guard needsWrite else { return }
        writer.async { [self] in
            guard let words = queue.sync(execute: { () -> LearnedWords? in
                defer { pending = nil }
                return pending
            }) else { return }
            write(words)
        }
    }

    /// Waits for queued writes to reach the file, for at most `timeout`.
    @discardableResult
    func flush(timeout: DispatchTimeInterval = .milliseconds(150)) -> Bool {
        let done = DispatchSemaphore(value: 0)
        writer.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Forgets every word and returns only once the empty list is on disk.
    ///
    /// Unlike a learned word, this is something the user asked for and was
    /// told had happened. Queued like a word, a reset the app was suspended
    /// before writing left the old file in place, and every word came back.
    func removeAll() {
        queue.sync {
            cached.removeAll()
            pending = nil
        }
        // Behind any write already queued, so an older list cannot land after.
        writer.sync { write(LearnedWords()) }
    }

    private func write(_ words: LearnedWords) {
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(words) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func read(from fileURL: URL?) -> LearnedWords? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let words = try? JSONDecoder().decode(LearnedWords.self, from: data)
        else { return nil }
        return words
    }
}
