import Foundation

/// Which letters sit under neighbouring keys, and what that costs a correction.
///
/// The system checker ranks its guesses by spelling alone: "hekki" and "hexxo"
/// are the same distance from "hello" as far as Levenshtein is concerned, but
/// only one of them is a hand that drifted one key right. A keyboard knows
/// something the dictionary does not — where the fingers were — and folding that
/// in is most of what separates a correction that lands from one that reads as
/// the keyboard guessing.
///
/// Adjacency is taken from the QWERTY layout rather than from the live key
/// frames on purpose. The rows are the same shape at every key height and on
/// every device, so a static table gives the same answer as measured geometry
/// while staying pure, cheap and testable — and it keeps working on the numbers
/// and symbols planes, where the letters are not on screen at all.
enum KeyProximity {
    /// The three letter rows, as laid out by ``KeyLayout``.
    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    /// How far the lower rows are indented, in key columns. The home row sits
    /// half a column in and the bottom row a full column, which is what makes
    /// "s" a neighbour of both "w" and "x" but not of "q".
    private static let rowOffsets: [Double] = [0, 0.5, 1.0]

    /// Column position of every letter, so adjacency is measured rather than
    /// enumerated by hand — a hand-written table of a hundred and some pairs is
    /// a place for exactly one typo to hide forever.
    private static let positions: [Character: (row: Int, column: Double)] = {
        var positions: [Character: (row: Int, column: Double)] = [:]
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, character) in row.enumerated() {
                positions[character] = (rowIndex, Double(columnIndex) + rowOffsets[rowIndex])
            }
        }
        return positions
    }()

    /// Keys within one column and one row of each other.
    ///
    /// Built once. `neighbours(of:)` is asked several times per candidate word
    /// during a correction, and rebuilding the set each time turned a cheap
    /// lookup into the most expensive part of ranking.
    private static let adjacency: [Character: Set<Character>] = {
        var adjacency: [Character: Set<Character>] = [:]
        for (character, position) in positions {
            var neighbours: Set<Character> = []
            for (other, otherPosition) in positions where other != character {
                guard abs(otherPosition.row - position.row) <= 1,
                      abs(otherPosition.column - position.column) <= 1.05
                else { continue }
                neighbours.insert(other)
            }
            adjacency[character] = neighbours
        }
        return adjacency
    }()

    static func neighbours(of character: Character) -> Set<Character> {
        adjacency[Character(String(character).lowercased())] ?? []
    }

    static func areAdjacent(_ left: Character, _ right: Character) -> Bool {
        guard left != right else { return false }
        return neighbours(of: left).contains(Character(String(right).lowercased()))
    }

    /// What it costs to say the user meant `intended` where they typed `typed`.
    ///
    /// A neighbouring key is the overwhelmingly common single-character error,
    /// so it costs less than half a full substitution. Anything else is a
    /// different letter entirely, and paying full price for it is what stops
    /// "cat" being offered for "bat" as readily as "hello" for "hwllo".
    static func substitutionCost(typed: Character, intended: Character) -> Double {
        if typed == intended { return 0 }
        let lowerTyped = Character(String(typed).lowercased())
        let lowerIntended = Character(String(intended).lowercased())
        if lowerTyped == lowerIntended { return 0 }
        return areAdjacent(lowerTyped, lowerIntended) ? 0.4 : 1
    }

    /// Damerau-Levenshtein with the substitution cost above, bounded.
    ///
    /// The same shape as ``TypingCandidates/editDistance(_:_:maximum:)`` — which
    /// stays, because the *unweighted* answer is still what the "is this a typo
    /// at all" threshold should be measured against — but the costs are real
    /// numbers, so a two-key drift can rank ahead of a one-key change to a
    /// letter on the other side of the keyboard.
    static func weightedDistance(_ left: String, _ right: String, maximum: Double) -> Double {
        if left == right { return 0 }
        let a = Array(left)
        let b = Array(right)
        // Insertions and deletions still cost one each, so a length gap alone
        // can already exceed the bound.
        if Double(abs(a.count - b.count)) > maximum { return maximum + 1 }
        if a.isEmpty { return min(Double(b.count), maximum + 1) }
        if b.isEmpty { return min(Double(a.count), maximum + 1) }

        var previousPrevious = [Double](repeating: 0, count: b.count + 1)
        var previous = (0...b.count).map(Double.init)
        var current = [Double](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = Double(i)
            var rowMinimum = current[0]
            for j in 1...b.count {
                let substitution = substitutionCost(typed: a[i - 1], intended: b[j - 1])
                var value = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + substitution
                )
                // Two fingers arriving in the wrong order. Cheap because it is
                // the one error class with no competing explanation.
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previousPrevious[j - 2] + 0.8)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > maximum { return maximum + 1 }
            swap(&previousPrevious, &previous)
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
