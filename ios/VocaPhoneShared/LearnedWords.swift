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
    /// Words seen fewer than ``repetitionsBeforeLearning`` times, kept apart
    /// from ``capacity`` so they never crowd out a learned word.
    static let sightingCapacity = 500
    /// How many times an unknown word has to survive being typed before the
    /// keyboard concludes the user meant it.
    static let repetitionsBeforeLearning = 3

    /// Every word seen, learned or not. A sighting is not a learned word: the
    /// keyboard notes each word its list does not know, which is mostly typos,
    /// so everything below reads only the entries that reached
    /// ``repetitionsBeforeLearning``.
    private(set) var entries: [String: Entry] = [:]

    /// Typos the user fixed by hand, by what they typed. Optional so files
    /// written before it decode. A typo fixed the same way
    /// ``fixesBeforeLearning`` times, and never another way, becomes a fix
    /// that space applies (`TypingCandidates.autocorrectDecision`); one fixed
    /// two ways, or whose fix was turned down, never does.
    private(set) var fixes: [String: Fix]?

    struct Fix: Codable, Equatable, Sendable {
        var fix: String
        var count: Int
        /// Fixed another way, or the applied fix was taken back.
        var conflicted: Bool
        var lastUsedAt: Date
    }

    static let fixesBeforeLearning = 2
    static let fixCapacity = 500

    /// Words the user long-pressed off the suggestion strip, by lowercase
    /// word, with when. Optional so files written before it decode.
    ///
    /// Kept here rather than in a file of its own because it is the same kind
    /// of thing — what this user has taught the keyboard — and it lives and
    /// dies with the same Full Access. Never listed in the app, for the same
    /// reason the learned words are not: a count and a reset are the feature.
    private(set) var blocked: [String: Date]?

    /// Enough for every word anyone would bother to block; the oldest go first.
    static let blockedCapacity = 500

    var blockedCount: Int { blocked?.count ?? 0 }

    /// Every blocked word, lowercased, for a keyboard to hold as a set rather
    /// than build one per keystroke.
    var blockedWords: Set<String> { blocked.map { Set($0.keys) } ?? [] }

    func isBlocked(_ word: String) -> Bool {
        blocked?[Self.key(word)] != nil
    }

    /// Never offer `word` again, and never correct to it.
    ///
    /// It also stops being a word this keyboard learned, and any typo fix that
    /// led to it is forgotten: a word the user asked not to see must not come
    /// back as a completion three sentences later because they once typed it.
    mutating func block(_ word: String, now: Date = Date()) {
        let key = Self.key(word)
        guard !key.isEmpty else { return }
        var all = blocked ?? [:]
        all[key] = now
        if all.count > Self.blockedCapacity {
            let doomed = all.sorted { $0.value < $1.value }.prefix(all.count - Self.blockedCapacity)
            for (word, _) in doomed { all.removeValue(forKey: word) }
        }
        blocked = all
        entries.removeValue(forKey: key)
        fixes = fixes?.filter { Self.key($0.value.fix) != key }
    }

    mutating func removeAllBlocked() {
        blocked = nil
    }

    /// What blocking a word took away, so Undo can put it back exactly: the
    /// learned entry and the typo fixes that led to it.
    struct Blocking: Equatable, Sendable {
        let word: String
        let entry: Entry?
        let fixes: [String: Fix]
        let wasBlocked: Bool
    }

    /// What ``block(_:now:)`` would take away, read before it does.
    func blocking(_ word: String) -> Blocking {
        let key = Self.key(word)
        return Blocking(
            word: word,
            entry: entries[key],
            fixes: fixes?.filter { Self.key($0.value.fix) == key } ?? [:],
            wasBlocked: isBlocked(word)
        )
    }

    /// Undo for a block: the word can be offered again, and what it took
    /// away comes back.
    mutating func undo(_ blocking: Blocking) {
        let key = Self.key(blocking.word)
        guard !key.isEmpty else { return }
        if !blocking.wasBlocked {
            blocked?.removeValue(forKey: key)
            if blocked?.isEmpty == true { blocked = nil }
        }
        if let entry = blocking.entry { entries[key] = entry }
        if !blocking.fixes.isEmpty {
            fixes = (fixes ?? [:]).merging(blocking.fixes) { _, restored in restored }
        }
    }

    private var learned: some Collection<Entry> {
        entries.values.lazy.filter { $0.count >= Self.repetitionsBeforeLearning }
    }

    var count: Int { learned.count }

    var words: [String] { learned.map(\.word) }

    func contains(_ word: String) -> Bool {
        (entries[Self.key(word)]?.count ?? 0) >= Self.repetitionsBeforeLearning
    }

    /// Words starting with `prefix`, most used first — someone who has typed a
    /// name forty times should see it before one they typed twice.
    func completions(for prefix: String, limit: Int) -> [String] {
        guard !prefix.isEmpty, limit > 0 else { return [] }
        let lowered = Self.key(prefix)
        return learned
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
        // Asserting a word is the opposite of blocking it, and the newer of
        // the two instructions is the one that stands.
        blocked?.removeValue(forKey: key)
        var entry = entries[key] ?? Entry(word: word, count: 0, lastUsedAt: now)
        entry.word = word
        entry.count = max(entry.count, Self.repetitionsBeforeLearning)
        entry.lastUsedAt = now
        entries[key] = entry
        evictIfNeeded()
    }

    /// Forgets learned words and fixes. Blocked words stay: "Reset learned
    /// words" promises nothing else is affected, and they have their own reset.
    mutating func removeAll() {
        entries.removeAll()
        fixes = nil
    }

    /// The user turned `typo` into `fix` by hand: picked it from the strip, or
    /// erased the word and typed it again.
    mutating func noteFix(typo: String, fix: String, now: Date = Date()) {
        let key = Self.key(typo)
        let fixed = fix.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !fixed.isEmpty, Self.key(fixed) != key else { return }
        var all = fixes ?? [:]
        if var known = all[key] {
            if Self.key(known.fix) == Self.key(fixed) {
                known.count += 1
                known.fix = fixed
            } else {
                known.conflicted = true
            }
            known.lastUsedAt = now
            all[key] = known
        } else {
            all[key] = Fix(fix: fixed, count: 1, conflicted: false, lastUsedAt: now)
        }
        if all.count > Self.fixCapacity {
            let doomed = all.sorted { $0.value.lastUsedAt < $1.value.lastUsedAt }
                .prefix(all.count - Self.fixCapacity)
            for (typo, _) in doomed { all.removeValue(forKey: typo) }
        }
        fixes = all
    }

    /// A learned fix was applied and then taken back: it never applies again.
    mutating func rejectFix(typo: String) {
        let key = Self.key(typo)
        guard var known = fixes?[key] else { return }
        known.conflicted = true
        fixes?[key] = known
    }

    /// What `typo` has been fixed to consistently, if it has.
    func learnedFix(for typo: String) -> String? {
        guard let known = fixes?[Self.key(typo)],
              !known.conflicted,
              known.count >= Self.fixesBeforeLearning
        else { return nil }
        return known.fix
    }

    var learnedFixCount: Int {
        fixes?.values.count { !$0.conflicted && $0.count >= Self.fixesBeforeLearning } ?? 0
    }

    /// Least-recently-used eviction, learned words and sightings each within
    /// their own bound: a run of typos never pushes out a name the user typed
    /// three times, and a store full of learned words still has room for a
    /// new word to be seen three times.
    private mutating func evictIfNeeded() {
        let threshold = Self.repetitionsBeforeLearning
        let learnedCount = entries.values.count { $0.count >= threshold }
        let sightings = entries.count - learnedCount
        if learnedCount > Self.capacity { evictOldest(learnedCount - Self.capacity) { $0.count >= threshold } }
        if sightings > Self.sightingCapacity { evictOldest(sightings - Self.sightingCapacity) { $0.count < threshold } }
    }

    private mutating func evictOldest(_ n: Int, where matches: (Entry) -> Bool) {
        let doomed = entries.values.filter(matches).sorted { $0.lastUsedAt < $1.lastUsedAt }.prefix(n)
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
    ///
    /// Starts from the file, not from this store's copy: Settings loads its
    /// store when it opens, and the keyboard may have blocked or learned
    /// words since. Writing the stale copy back would undo those.
    func removeAll() {
        rewrite { $0.removeAll() }
    }

    /// Unblocks every word, the same way: on disk before it returns, and
    /// starting from the file, so words learned since are not lost.
    func removeAllBlocked() {
        rewrite { $0.removeAllBlocked() }
    }

    /// Applies `change` to the file as it is now and writes the result,
    /// behind any write already queued so an older list cannot land after.
    private func rewrite(_ change: (inout LearnedWords) -> Void) {
        writer.sync {
            let onDisk = Self.read(from: fileURL)
            let remaining = queue.sync { () -> LearnedWords in
                var words = onDisk ?? cached
                change(&words)
                cached = words
                pending = nil
                return words
            }
            write(remaining)
        }
    }

    /// Picks up what another process wrote — Settings' resets above — so a
    /// long-lived keyboard does not write its old copy back over them.
    ///
    /// Read on the writer queue, behind any write of this store's own, and
    /// handed back on the main queue. Skipped while a change of this store's
    /// is still waiting to be written: that change is newer than the file.
    func reload(_ completion: @escaping @Sendable (LearnedWords) -> Void) {
        writer.async { [self] in
            // No file (no Full Access, or nothing written yet): the copy in
            // memory is all there is.
            guard let onDisk = Self.read(from: fileURL) else { return }
            let words = queue.sync { () -> LearnedWords? in
                guard pending == nil else { return nil }
                cached = onDisk
                return onDisk
            }
            guard let words else { return }
            DispatchQueue.main.async { completion(words) }
        }
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
