import UIKit

/// The three questions typing intelligence asks a dictionary.
///
/// Behind a protocol because the real implementation is `UITextChecker`, which
/// reads the *user's* device dictionaries — those differ between machines,
/// between iOS versions, and after the user adds a word in another app. A test
/// that asserts "teh" → "the" against it is a flake waiting to happen, so tests
/// drive ``TypingCandidates`` through a fixture and one tolerant smoke test
/// confirms the real checker is reachable.
///
/// Main-actor isolated, because `UITextChecker` is: the SDK marks it
/// `NS_SWIFT_UI_ACTOR`, which is a per-class annotation Apple wrote
/// deliberately, not UIKit's blanket one. The plan assumed this work could be
/// pushed onto a serial background queue; the platform says otherwise, so the
/// keystroke is kept unblocked a different way — see ``TypingEngine``.
@MainActor
protocol SpellChecking: AnyObject {
    /// Longer words beginning with `prefix`.
    func completions(for prefix: String, language: String) -> [String]
    /// Replacements for a word the checker does not recognise.
    func guesses(for word: String, language: String) -> [String]
    /// Whether the checker recognises the word at all.
    func isKnown(_ word: String, language: String) -> Bool
}

/// `UITextChecker`, which is the whole reason iOS needs no shipped dictionary:
/// it is the system's own, in every language the user has installed.
///
/// One instance. A second one also means a second copy of the loaded language
/// data, which matters when the whole extension is fighting for 45–60 MB.
@MainActor
final class SystemSpellChecker: SpellChecking {
    /// Built on first use, never at launch.
    ///
    /// `UITextChecker` loads the user's dictionaries, and a keyboard extension
    /// is killed somewhere around 45–60 MB. Constructing it while the keyboard
    /// is still trying to appear spends that budget before the user has typed
    /// anything — and a keyboard that is jetsammed on launch looks to its owner
    /// like a keyboard that will not open.
    private var loaded: UITextChecker?

    private var checker: UITextChecker {
        if let loaded { return loaded }
        let created = UITextChecker()
        loaded = created
        return created
    }

    /// Whether the dictionaries have actually been paid for yet.
    var isLoaded: Bool { loaded != nil }

    /// The languages the checker has data for. Also deferred: enumerating them
    /// touches the same dictionaries.
    private nonisolated(unsafe) static var cachedLanguages: [String]?

    static func availableLanguages() -> [String] {
        if let cachedLanguages { return cachedLanguages }
        let languages = UITextChecker.availableLanguages
        cachedLanguages = languages
        return languages
    }

    func completions(for prefix: String, language: String) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        return checker.completions(
            forPartialWordRange: range,
            in: prefix,
            language: language
        ) ?? []
    }

    func guesses(for word: String, language: String) -> [String] {
        guard !word.isEmpty else { return [] }
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.guesses(forWordRange: range, in: word, language: language) ?? []
    }

    func isKnown(_ word: String, language: String) -> Bool {
        guard !word.isEmpty else { return false }
        let text = word as NSString
        let misspelled = checker.rangeOfMisspelledWord(
            in: word,
            range: NSRange(location: 0, length: text.length),
            startingAt: 0,
            wrap: false,
            language: language
        )
        return misspelled.location == NSNotFound
    }
}

/// A bounded most-recently-used cache.
///
/// This is what makes a main-actor spell checker affordable: typing "hell"
/// after "hel" must not recompute "hel", and a user backspacing through a word
/// walks straight back over prefixes they just paid for. Small on purpose —
/// this lives inside an extension with a hard memory ceiling, and 64 entries is
/// several seconds of fast typing.
struct SuggestionCache {
    struct Key: Hashable {
        let prefix: String
        let language: String
    }

    struct Value: Equatable {
        var completions: [String]
        var guesses: [String]
        var isKnown: Bool
        /// Near-matches from the shipped word list.
        ///
        /// Cached here rather than recomputed per keystroke, which is what it
        /// used to be: `similarWords` scans the list computing edit distances,
        /// it runs on the main actor, and it ran on the *cache hit* path too —
        /// so the cache that exists to keep the checker off the keystroke was
        /// letting an equally expensive scan straight through it. Typing a name,
        /// which is exactly when nothing is in the list, was the worst case.
        var similar: [String] = []
    }

    private var storage: [Key: Value] = [:]
    /// Least-recently-used first.
    private var order: [Key] = []
    private let limit: Int

    init(limit: Int = 64) {
        self.limit = max(1, limit)
    }

    var count: Int { storage.count }

    mutating func value(for key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        storage[key] = value
        touch(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}
