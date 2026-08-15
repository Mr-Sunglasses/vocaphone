import Foundation

/// The frequency-ordered word list and next-word table, shared with the Android
/// keyboard.
///
/// Two things `UITextChecker` cannot do, and the only reason iOS ships any word
/// data at all:
///
/// 1. **Next-word prediction.** The system checker has no such API.
/// 2. **Frequency order.** `UITextChecker.completions` returns candidates in no
///    useful order, so "th" can suggest "thymus" ahead of "the". Re-ranking
///    against a frequency list is what makes the strip feel like the system
///    keyboard's rather than a dictionary dump.
///
/// Both files live once, at `assets/keyboard/` in the repository root, and reach
/// this bundle through `project.yml` and the Android bundle through
/// `sourceSets` in `app/build.gradle.kts`.
struct TypingWordList: Sendable {
    /// Frequency rank by lowercase word — 0 is the most common word in the
    /// language. Also serves as the membership test.
    private let ranks: [String: Int]
    private let words: [String]
    private let bigrams: [String: [String]]

    static let empty = TypingWordList(words: [], bigrams: [:])

    init(words: [String], bigrams: [String: [String]]) {
        self.words = words
        self.bigrams = bigrams
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(words.count)
        for (rank, word) in words.enumerated() where ranks[word] == nil {
            ranks[word] = rank
        }
        self.ranks = ranks
    }

    var isEmpty: Bool { words.isEmpty }

    /// The list in frequency order, for callers that need to rank against it —
    /// the swipe recogniser scores every plausible word and needs both the word
    /// and how common it is.
    var rankedWords: [String] { words }

    var count: Int { words.count }

    func rank(of word: String) -> Int? { ranks[word.lowercased()] }

    func contains(_ word: String) -> Bool { ranks[word.lowercased()] != nil }

    /// Words starting with `prefix`, most common first. Bounded because the
    /// strip shows three chips and scanning the whole list to sort ten thousand
    /// matches would be work nobody sees.
    func completions(for prefix: String, limit: Int) -> [String] {
        guard !prefix.isEmpty, limit > 0 else { return [] }
        let lowered = prefix.lowercased()
        var found: [String] = []
        found.reserveCapacity(limit)
        // `words` is already frequency-ordered, so the first matches found are
        // the best ones and the scan can stop early.
        for word in words where word.count > lowered.count && word.hasPrefix(lowered) {
            found.append(word)
            if found.count == limit { break }
        }
        return found
    }

    /// Words within a small edit distance of `typed`, most common first.
    ///
    /// The shipped list's answer to "what did they mean", used two ways: as a
    /// supplement to the system checker's guesses, and as the whole correction
    /// source if the checker ever has to be dropped for cost — the fallback
    /// held in reserve for that. Bounded by length before distance is computed,
    /// so the scan skips most of the list without looking at it.
    func similarWords(to typed: String, limit: Int) -> [String] {
        let lowered = typed.lowercased()
        guard lowered.count >= 3, limit > 0, ranks[lowered] == nil else { return [] }
        let shortest = max(1, lowered.count - 2)
        let longest = lowered.count + 2
        var withinOne: [String] = []
        var withinTwo: [String] = []
        for word in words {
            guard word.count >= shortest, word.count <= longest else { continue }
            switch TypingCandidates.editDistance(lowered, word, maximum: 2) {
            case 1: withinOne.append(word)
            case 2: if withinTwo.count < limit { withinTwo.append(word) }
            default: continue
            }
            // `words` is frequency-ordered, so the first close match found is
            // also the most likely one and the scan can stop early.
            if withinOne.count >= limit { break }
        }
        return Array((withinOne + withinTwo).prefix(limit))
    }

    /// What usually follows `word`.
    func nextWords(after word: String, limit: Int) -> [String] {
        guard !word.isEmpty, limit > 0 else { return [] }
        return Array(bigrams[word.lowercased(), default: []].prefix(limit))
    }

    // MARK: - Loading

    /// Parses the two shipped files. Both formats are the Android ones, because
    /// they are the same two files.
    static func parse(words wordsText: String, bigrams bigramsText: String) -> TypingWordList {
        let words = wordsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var bigrams: [String: [String]] = [:]
        for line in bigramsText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let word = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let continuations = parts[1]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !word.isEmpty, !continuations.isEmpty else { continue }
            bigrams[word] = continuations
        }
        return TypingWordList(words: words, bigrams: bigrams)
    }

    /// Reads both files from a bundle. Returns ``empty`` rather than throwing:
    /// a keyboard with no word list still types, completes through the system
    /// checker, and corrects — it only loses prediction and re-ranking, which
    /// is a much better failure than not appearing at all.
    static func load(from bundle: Bundle) -> TypingWordList {
        guard let wordsURL = bundle.url(forResource: "en", withExtension: "txt"),
              let bigramsURL = bundle.url(forResource: "en-bigrams", withExtension: "txt"),
              let wordsText = try? String(contentsOf: wordsURL, encoding: .utf8),
              let bigramsText = try? String(contentsOf: bigramsURL, encoding: .utf8)
        else { return .empty }
        return parse(words: wordsText, bigrams: bigramsText)
    }
}
