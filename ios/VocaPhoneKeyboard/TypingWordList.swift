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
    /// Where in `words` to start looking for a prefix, keyed by its first one
    /// and two characters, each bucket in frequency order.
    ///
    /// Every prefix query used to walk the whole list — ten thousand words, and
    /// a grapheme-counting `word.count` on each — because a frequency-ordered
    /// list cannot be searched. `scanLimit` bounded the number of *matches*, not
    /// the scan, so a rare prefix paid for all ten thousand. Measured on device
    /// that was 5.5 ms of a 9.5 ms keystroke, on a frame budget of 8.3.
    ///
    /// Positions rather than words: the weight below is a function of a word's
    /// rank in the whole list, so a bucket has to remember where its words came
    /// from.
    private let prefixIndex: [String: [Int32]]
    /// Each word's length, so a query that only wants to know whether a word is
    /// the right size never walks its graphemes to find out.
    private let lengths: [Int]
    /// Each word with consecutive repeats removed, in `words` order.
    ///
    /// Built once with the list rather than per swipe. The recogniser needs the
    /// collapsed form of every word to test it against a trace, and deriving
    /// ten thousand of them inside the gesture meant ten thousand String
    /// allocations on the main actor at the exact frame the finger lifted — the
    /// one moment in this keyboard where a hitch is guaranteed to be seen.
    let collapsedWords: [String]

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
        collapsedWords = words.map(SwipeRecognizer.collapsed)
        lengths = words.map(\.count)
        var index: [String: [Int32]] = [:]
        index.reserveCapacity(words.count / 8)
        for (position, word) in words.enumerated() {
            let one = String(word.prefix(1))
            index[one, default: []].append(Int32(position))
            guard word.count > 1 else { continue }
            index[String(word.prefix(2)), default: []].append(Int32(position))
        }
        prefixIndex = index
    }

    /// The positions worth looking at for `lowered`, in frequency order, or
    /// `nil` when the list has nothing that starts that way.
    ///
    /// Keyed on at most the first two characters, which is all it takes: after
    /// two the buckets are already small enough that the difference is not
    /// worth the memory of a third.
    private func positions(startingWith lowered: String) -> [Int32]? {
        prefixIndex[String(lowered.prefix(2))]
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
        guard let positions = positions(startingWith: lowered) else { return [] }
        var found: [String] = []
        found.reserveCapacity(limit)
        // The bucket is in frequency order, so the first matches found are the
        // best ones and the scan can stop early.
        for position in positions {
            let word = words[Int(position)]
            guard word != lowered, word.hasPrefix(lowered) else { continue }
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
        for (position, word) in words.enumerated() {
            let length = lengths[position]
            guard length >= shortest, length <= longest else { continue }
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

    /// How likely each letter is to be the next one typed, given the prefix
    /// already composed. Weights are relative, and the largest is always 1.
    ///
    /// This is the language half of the touch model. The system keyboard quietly
    /// grows a key's *invisible* hit region when the language expects that
    /// letter — after "th" the "e" claims more of the gutter than the "w" beside
    /// it — which is a large part of why it forgives a finger that lands between
    /// two keys and this keyboard did not.
    ///
    /// Bounded hard. It runs on the keystroke path, and the answer only has to
    /// separate "expected" from "not expected": scanning the most common few
    /// hundred matches gives the same ordering as scanning ten thousand, for a
    /// fraction of the work.
    func nextCharacterWeights(after prefix: String, scanLimit: Int = 400) -> [Character: Double] {
        guard !prefix.isEmpty else { return [:] }
        let lowered = prefix.lowercased()
        guard let positions = positions(startingWith: lowered) else { return [:] }
        var weights: [Character: Double] = [:]
        var matches = 0
        // The bucket carries each word's rank in the whole list, so a match
        // found early is still a more likely continuation than one found late —
        // which is exactly the weighting wanted, and it still comes for free
        // from the order.
        for position in positions {
            let word = words[Int(position)]
            guard word != lowered, word.hasPrefix(lowered) else { continue }
            let next = word[word.index(word.startIndex, offsetBy: lowered.count)]
            weights[next, default: 0] += 1 / (1 + Double(position) / 500)
            matches += 1
            if matches >= scanLimit { break }
        }
        guard let peak = weights.values.max(), peak > 0 else { return [:] }
        return weights.mapValues { $0 / peak }
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
