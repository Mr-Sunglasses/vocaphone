import Foundation

/// Writing check's spelling: whether a word is in the dictionary, and if not,
/// the word the user most likely meant. Mirrors `WritingSpelling.kt`, which
/// says how; both are tested against `assets/grammar/writing_fixtures.json`.
///
/// The dictionary is kept as sorted byte runs, one array per word length,
/// about a megabyte in all, so it fits beside the rules in the keyboard
/// extension.
final class WritingSpelling: Sendable {
    /// What `suggest` found: the word, how far it is, and whether it is clearly the one.
    struct Guess: Equatable, Sendable {
        let word: String
        let edits: Int
        let score: Int
        let sure: Bool
    }

    static let edit = 10
    static let neighbour = 7
    static let vowels = 8
    static let double = 5
    static let transpose = 6
    /// An edit counts this many times a frequency step: spelling comes before popularity.
    static let distanceWeight = 3
    /// How far ahead the best guess must be to be sure: accepted with "Accept all".
    static let sureMargin = 8
    /// From this length a word may be two edits from what was meant.
    static let long = 6
    static let minLength = 3
    static let maxLength = 24

    /// Lower-case words that may be suggested, by length: sorted, fixed-width runs.
    private let words: [[UInt8]]
    /// Each word's frequency cost, in the same order as `words`.
    private let costs: [[UInt8]]
    /// Words accepted but never suggested (names, chat words), lower case, by length.
    private let accepted: [[UInt8]]
    /// Names accepted only with their capitals, by length.
    private let proper: [[UInt8]]

    private init(words: [[UInt8]], costs: [[UInt8]], accepted: [[UInt8]], proper: [[UInt8]]) {
        self.words = words
        self.costs = costs
        self.accepted = accepted
        self.proper = proper
    }

    /// Whether `word`, exactly as typed (letters and apostrophes, ASCII), is spelled right.
    func isKnown(_ word: String) -> Bool {
        guard let bytes = Self.ascii(word) else { return true }
        if Self.contains(proper, bytes) { return true }
        let lower = bytes.map(Self.lowerByte)
        if Self.contains(words, lower) || Self.contains(accepted, lower) { return true }
        // A name typed in lower case ("facebook", "paris"), from four letters on.
        if lower.count >= 4, Self.containsLowered(proper, lower) { return true }
        // A possessive: "dog's", "James's".
        if lower.count > 2, lower[lower.count - 2] == Self.apostrophe, lower[lower.count - 1] == UInt8(ascii: "s") {
            let stem = String(word.dropLast(2))
            return !stem.isEmpty && isKnown(stem)
        }
        return false
    }

    /// The dictionary word `word` most likely meant, or nil when none is close
    /// enough. `word` is lower case ASCII letters.
    func suggest(_ word: String) -> Guess? {
        guard let typed = Self.ascii(word) else { return nil }
        let n = typed.count
        guard n >= Self.minLength, n <= Self.maxLength else { return nil }
        let maxEdits = n >= Self.long ? 2 : 1
        let limit = maxEdits * Self.edit
        var best: Guess?
        var bestScore = Int.max
        var bestCost = 0
        var secondScore = Int.max
        var r0 = [Int](repeating: 0, count: Self.maxLength + 3)
        var r1 = r0
        var r2 = r0
        let starts = Self.firstLetters(typed)
        for length in max(1, n - maxEdits)...min(Self.maxLength, n + maxEdits) {
            let bucket = words[length]
            let count = bucket.count / length
            let lengthCosts = costs[length]
            // The bucket is sorted, so each first letter is one run of it.
            for first in starts {
                let from = Self.lowerBound(bucket, length, count, Int(first))
                let to = Self.lowerBound(bucket, length, count, Int(first) + 1)
                for k in from..<to {
                    let at = k * length
                    let cost = Self.distance(typed, bucket, at, length, limit, &r0, &r1, &r2)
                    if cost > limit { continue }
                    let frequency = Int(lengthCosts[k])
                    let score = cost * Self.distanceWeight + frequency
                    if score < bestScore || (score == bestScore && frequency < bestCost) {
                        if best != nil { secondScore = min(secondScore, bestScore) }
                        bestScore = score
                        bestCost = frequency
                        let text = String(decoding: bucket[at..<(at + length)], as: UTF8.self)
                        best = Guess(word: text, edits: (cost + Self.edit - 1) / Self.edit, score: score, sure: false)
                    } else if score < secondScore {
                        secondScore = score
                    }
                }
            }
        }
        guard let found = best else { return nil }
        let sure = found.edits == 1 && secondScore - bestScore >= Self.sureMargin
        return Guess(word: found.word, edits: found.edits, score: found.score, sure: sure)
    }

    // MARK: - Distance

    /// The first letters a meant word may have, in alphabetical order. See
    /// `WritingSpelling.kt`.
    private static func firstLetters(_ typed: [UInt8]) -> [UInt8] {
        var set = Set<UInt8>([typed[0]])
        if typed.count > 1 { set.insert(typed[1]) }
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") where adjacent(c, typed[0]) { set.insert(c) }
        return set.sorted()
    }

    /// The first word in `bucket` (of `count` words of `length`) whose first letter is at least `first`.
    private static func lowerBound(_ bucket: [UInt8], _ length: Int, _ count: Int, _ first: Int) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(bucket[mid * length]) < first { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Weighted optimal-string-alignment distance from `a` (as typed) to the
    /// word at `at` in `b`, in tenths of an edit, or anything above `limit`
    /// once it cannot come back under it. See `WritingSpelling.kt`.
    private static func distance(
        _ a: [UInt8], _ b: [UInt8], _ at: Int, _ m: Int, _ limit: Int,
        _ cur: inout [Int], _ prev: inout [Int], _ prev2: inout [Int]
    ) -> Int {
        let n = a.count
        prev[0] = 0
        for j in 1...m { prev[j] = prev[j - 1] + insertCost(b, at, j) }
        for i in 1...n {
            cur[0] = prev[0] + deleteCost(a, i)
            var rowMin = cur[0]
            let x = a[i - 1]
            for j in 1...m {
                let y = b[at + j - 1]
                var d = min(prev[j] + deleteCost(a, i), cur[j - 1] + insertCost(b, at, j))
                d = min(d, prev[j - 1] + substituteCost(x, y))
                if i > 1, j > 1, x == b[at + j - 2], a[i - 2] == y, x != y {
                    d = min(d, prev2[j - 2] + transpose)
                }
                cur[j] = d
                if d < rowMin { rowMin = d }
            }
            if rowMin > limit { return limit + 1 }
            // (prev2, prev, cur) ← (prev, cur, prev2)
            swap(&prev2, &prev)
            swap(&prev, &cur)
        }
        return prev[m]
    }

    private static func deleteCost(_ a: [UInt8], _ i: Int) -> Int { i > 1 && a[i - 1] == a[i - 2] ? double : edit }

    private static func insertCost(_ b: [UInt8], _ at: Int, _ j: Int) -> Int {
        j > 1 && b[at + j - 1] == b[at + j - 2] ? double : edit
    }

    private static func substituteCost(_ x: UInt8, _ y: UInt8) -> Int {
        if x == y { return 0 }
        if adjacent(x, y) { return neighbour }
        if isVowel(x), isVowel(y) { return vowels }
        return edit
    }

    // MARK: - Lookup

    private static func contains(_ table: [[UInt8]], _ word: [UInt8]) -> Bool {
        let n = word.count
        guard n > 0, n < table.count else { return false }
        let bucket = table[n]
        var lo = 0
        var hi = bucket.count / n - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = compare(bucket, mid * n, word)
            if c < 0 { lo = mid + 1 } else if c > 0 { hi = mid - 1 } else { return true }
        }
        return false
    }

    private static func containsLowered(_ table: [[UInt8]], _ lower: [UInt8]) -> Bool {
        let n = lower.count
        guard n < table.count else { return false }
        let bucket = table[n]
        var at = 0
        while at < bucket.count {
            var same = true
            for k in 0..<n where lowerByte(bucket[at + k]) != lower[k] {
                same = false
                break
            }
            if same { return true }
            at += n
        }
        return false
    }

    private static func compare(_ bucket: [UInt8], _ at: Int, _ word: [UInt8]) -> Int {
        for k in 0..<word.count {
            let d = Int(bucket[at + k]) - Int(word[k])
            if d != 0 { return d }
        }
        return 0
    }

    // MARK: - Building

    /// The rank a word outside `en.txt` takes, by the SCOWL size it is in.
    private static let sectionRank = ["35": 12_000, "40": 25_000, "50": 50_000, "60": 90_000]

    /// How much rarer than "the" a word is: about twice log₂ of its rank, in whole steps.
    static func frequencyCost(_ rank: Int) -> Int {
        let square = UInt64(rank) * UInt64(rank)
        return 63 - square.leadingZeroBitCount
    }

    /// The dictionary the app or keyboard ships, or nil if a file is missing.
    static func bundled(_ bundle: Bundle = .main) -> WritingSpelling? {
        guard let spelling = bundle.url(forResource: "en-spelling", withExtension: "txt").flatMap({ try? Data(contentsOf: $0) }),
              let frequency = bundle.url(forResource: "en", withExtension: "txt").flatMap({ try? Data(contentsOf: $0) })
        else { return nil }
        return parse(spelling: spelling, frequency: frequency)
    }

    /// Builds the dictionary from `en-spelling.txt` and `en.txt`. Reads the
    /// bytes line by line rather than splitting them, so the keyboard
    /// extension never holds the file and its lines at once. Takes tens of
    /// milliseconds: callers build one off the main thread and keep it.
    static func parse(spelling: Data, frequency: Data) -> WritingSpelling {
        var rank: [[UInt8]: Int] = [:]
        var r = 0
        forEachLine(frequency) { line in
            if !line.isEmpty, rank[line] == nil {
                r += 1
                rank[line] = r
            }
        }
        var suggestable = [[([UInt8], UInt8)]](repeating: [], count: maxLength + 1)
        var acceptedLists = [[[UInt8]]](repeating: [], count: maxLength + 1)
        var properLists = [[[UInt8]]](repeating: [], count: maxLength + 1)
        var section: [UInt8] = []
        forEachLine(spelling) { line in
            guard let first = line.first, first != UInt8(ascii: "#") else { return }
            if first == UInt8(ascii: "@") {
                section = Array(line.dropFirst())
                return
            }
            guard line.count <= maxLength, line.allSatisfy({ $0 < 128 }) else { return }
            switch String(decoding: section, as: UTF8.self) {
            case "proper": properLists[line.count].append(line)
            case "accept": acceptedLists[line.count].append(line)
            case let name:
                guard let base = sectionRank[name] else { return }
                suggestable[line.count].append((line, UInt8(frequencyCost(rank[line] ?? base))))
            }
        }
        let less: ([UInt8], [UInt8]) -> Bool = { x, y in x.lexicographicallyPrecedes(y) }
        var words: [[UInt8]] = []
        var costs: [[UInt8]] = []
        for n in 0...maxLength {
            let sorted = suggestable[n].sorted { less($0.0, $1.0) }
            words.append(sorted.flatMap(\.0))
            costs.append(sorted.map(\.1))
        }
        let accepted = (0...maxLength).map { acceptedLists[$0].sorted(by: less).flatMap { $0 } }
        let proper = (0...maxLength).map { properLists[$0].sorted(by: less).flatMap { $0 } }
        return WritingSpelling(words: words, costs: costs, accepted: accepted, proper: proper)
    }

    /// Each line of `data`, without its line break or surrounding spaces.
    private static func forEachLine(_ data: Data, _ body: ([UInt8]) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            for i in 0...bytes.count {
                guard i == bytes.count || bytes[i] == 0x0A else { continue }
                var lo = start
                var hi = i
                while lo < hi, bytes[lo] == 0x20 || bytes[lo] == 0x09 || bytes[lo] == 0x0D { lo += 1 }
                while hi > lo, bytes[hi - 1] == 0x20 || bytes[hi - 1] == 0x09 || bytes[hi - 1] == 0x0D { hi -= 1 }
                body(Array(bytes[lo..<hi]))
                start = i + 1
            }
        }
    }

    /// `word` as ASCII bytes, curly apostrophes straightened; nil if it has anything else.
    static func ascii(_ word: String) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(word.utf16.count)
        for unit in word.utf16 {
            let u = unit == 0x2019 ? 0x27 : unit
            guard u < 128 else { return nil }
            out.append(UInt8(u))
        }
        return out
    }

    private static let apostrophe = UInt8(ascii: "'")

    private static func lowerByte(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b + 32 : b }

    private static func isVowel(_ b: UInt8) -> Bool { b == 97 || b == 101 || b == 105 || b == 111 || b == 117 }

    /// QWERTY neighbours, staggered: "s" touches "a", "d", "w", "e", "z" and "x".
    private static let neighbours: [[Bool]] = {
        var table = [[Bool]](repeating: [Bool](repeating: false, count: 128), count: 128)
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0.utf8) }
        func link(_ a: UInt8, _ b: UInt8) {
            table[Int(a)][Int(b)] = true
            table[Int(b)][Int(a)] = true
        }
        for (r, row) in rows.enumerated() {
            for (k, c) in row.enumerated() {
                if k + 1 < row.count { link(c, row[k + 1]) }
                if r + 1 < rows.count {
                    let below = rows[r + 1]
                    if k - 1 >= 0, k - 1 < below.count { link(c, below[k - 1]) }
                    if k < below.count { link(c, below[k]) }
                }
            }
        }
        return table
    }()

    private static func adjacent(_ x: UInt8, _ y: UInt8) -> Bool { x < 128 && y < 128 && neighbours[Int(x)][Int(y)] }
}
