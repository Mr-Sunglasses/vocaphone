import CoreGraphics
import Foundation

/// Turns a traced path across the keys into candidate words.
///
/// The algorithm is the Android client's — collapse the path to a letter
/// sequence, require the first and last keys to match within a neighbour
/// radius, filter by subsequence, then score by how closely the traced shape
/// matches the ideal path through the word's keys, plus frequency. The *code*
/// is not shared: this one is fed by the key centres ``KeyGridView`` already
/// computes during layout, so it works at any width and any height preference
/// rather than against a normalised grid.
///
/// Pure, and driven by injected key centres, so the whole recogniser can be
/// tested without a touch.
struct SwipeRecognizer {
    struct Key: Equatable {
        let character: Character
        let centre: CGPoint
    }

    /// How far a finger must leave the first key before this is a swipe rather
    /// than a correction. Sliding a little to fix a target is an interaction
    /// the keyboard already has, and stealing it would break ordinary typing.
    static let activationDistance: CGFloat = 26

    private let keys: [Key]
    /// Derived from the keys themselves rather than assumed: a Compact keyboard
    /// on a 320pt phone has very different spacing from a Tall one on a Max.
    private let neighbourRadius: CGFloat

    init(keys: [Key]) {
        self.keys = keys
        // 1.4 × the typical column pitch: far enough to include the keys either
        // side and the ones above and below, not so far as to include a third
        // of the alphabet.
        let pitch = Self.medianPitch(of: keys)
        neighbourRadius = pitch * 1.4
    }

    var isUsable: Bool { keys.count > 10 }

    // MARK: - Tracing

    /// The letters a path passed over, with consecutive repeats collapsed.
    ///
    /// Repeats are dropped because a finger lingers: three samples inside "e"
    /// are one intentional "e", and "eee" matches nothing.
    func trace(_ points: [CGPoint]) -> String {
        var letters = ""
        for point in points {
            guard let key = nearestKey(to: point) else { continue }
            if letters.last != key.character { letters.append(key.character) }
        }
        return letters
    }

    func nearestKey(to point: CGPoint) -> Key? {
        keys.min { first, second in
            Self.distance(first.centre, point) < Self.distance(second.centre, point)
        }
    }

    /// Letters whose keys sit within a finger's slop of this one.
    func neighbours(of character: Character) -> Set<Character> {
        guard let origin = keys.first(where: { $0.character == character }) else { return [] }
        return Set(
            keys
                .filter {
                    $0.character != character
                        && Self.distance($0.centre, origin.centre) < neighbourRadius
                }
                .map(\.character)
        )
    }

    // MARK: - Matching

    /// The best words for a traced path, most likely first.
    func candidates(for trace: String, in wordList: TypingWordList, limit: Int = 4) -> [String] {
        // Without key positions there is no shape to compare against, and the
        // scoring would degenerate into "any word with these letters in order" —
        // which is a guess dressed as a recognition. The caller checks
        // `isUsable` too; this is the guard that makes the function safe on its
        // own.
        guard isUsable else { return [] }
        let path = Self.collapsed(trace)
        guard path.count >= 2, let first = path.first, let last = path.last else { return [] }

        let starts = neighbours(of: first).union([first])
        let ends = neighbours(of: last).union([last])

        var scored: [(word: String, score: CGFloat)] = []
        for (rank, word) in wordList.rankedWords.enumerated() {
            let compact = Self.collapsed(word)
            guard compact.count >= 2,
                  let wordFirst = compact.first,
                  let wordLast = compact.last,
                  starts.contains(wordFirst),
                  ends.contains(wordLast),
                  // Every letter of the word has to appear along the path, in
                  // order. A finger that never passed over "k" did not mean a
                  // word containing one.
                  Self.isSubsequence(compact, of: path)
            else { continue }
            scored.append((word, score(path: path, word: compact, frequencyRank: rank)))
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.word)
    }

    /// Higher is better. Shape dominates, frequency breaks ties, and a word
    /// whose ends do not match the trace's ends is penalised heavily — those
    /// are the two keys the user was most deliberate about.
    func score(path: String, word: String, frequencyRank: Int) -> CGFloat {
        let shape = shapeDistance(path: path, word: word)
        let lengthGap = abs(pathLength(path) - pathLength(word))
        let endPenalty = (word.first == path.first ? 0 : 0.7)
            + (word.last == path.last ? 0 : 0.7)
        let frequency = 1 / (1 + CGFloat(frequencyRank) / 400)
        // Normalised by the neighbour radius so the weights mean the same thing
        // at every key size.
        let scale = max(neighbourRadius, 1)
        return frequency * 2
            - (shape / scale) * 3
            - (lengthGap / scale) * 0.35
            - endPenalty
    }

    /// Mean distance between the traced path and the ideal one through the
    /// word's keys, both resampled to the same number of points.
    func shapeDistance(path: String, word: String) -> CGFloat {
        let traced = sample(path)
        let ideal = sample(word)
        guard !traced.isEmpty, ideal.count == traced.count else { return .greatestFiniteMagnitude }
        let total = zip(traced, ideal).reduce(CGFloat.zero) { $0 + Self.distance($1.0, $1.1) }
        return total / CGFloat(traced.count)
    }

    private static let samplePoints = 12

    /// Resamples the polyline through a string's key centres at even spacing,
    /// which is what makes two paths of different lengths comparable.
    func sample(_ letters: String) -> [CGPoint] {
        let points = letters.compactMap { character in
            keys.first { $0.character == character }?.centre
        }
        guard !points.isEmpty else { return [] }
        guard points.count > 1 else {
            return Array(repeating: points[0], count: Self.samplePoints)
        }
        var cumulative: [CGFloat] = [0]
        for index in 1..<points.count {
            cumulative.append(cumulative[index - 1] + Self.distance(points[index - 1], points[index]))
        }
        let total = max(cumulative.last ?? 0, 0.0001)
        return (0..<Self.samplePoints).map { step in
            let target = total * CGFloat(step) / CGFloat(Self.samplePoints - 1)
            var index = 1
            while index < cumulative.count - 1 && cumulative[index] < target { index += 1 }
            let start = cumulative[index - 1]
            let span = max(cumulative[index] - start, 0.0001)
            let t = min(max((target - start) / span, 0), 1)
            let from = points[index - 1]
            let to = points[index]
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
    }

    private func pathLength(_ letters: String) -> CGFloat {
        let points = letters.compactMap { character in
            keys.first { $0.character == character }?.centre
        }
        guard points.count > 1 else { return 0 }
        return (1..<points.count).reduce(CGFloat.zero) {
            $0 + Self.distance(points[$1 - 1], points[$1])
        }
    }

    // MARK: - Helpers

    static func collapsed(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() where character.isLetter {
            if result.last != character { result.append(character) }
        }
        return result
    }

    static func isSubsequence(_ word: String, of path: String) -> Bool {
        var remaining = Substring(word)
        for character in path where character == remaining.first {
            remaining = remaining.dropFirst()
        }
        return remaining.isEmpty
    }

    static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func medianPitch(of keys: [Key]) -> CGFloat {
        guard keys.count > 1 else { return 40 }
        // Nearest-neighbour distance for each key: the column pitch, whatever
        // the current geometry happens to be.
        let distances = keys.map { key in
            keys
                .filter { $0.character != key.character }
                .map { distance($0.centre, key.centre) }
                .min() ?? 40
        }
        .sorted()
        return distances[distances.count / 2]
    }
}
