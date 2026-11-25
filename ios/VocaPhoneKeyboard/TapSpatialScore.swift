import Foundation

/// Where a finger landed inside the key it pressed: the offset from the key's
/// centre in key widths (`dx`, right is positive) and key heights (`dy`, down
/// is positive). Recorded per typed letter (`TypingEngine`).
struct TapOffset: Equatable, Sendable {
    var dx: Double
    var dy: Double
}

/// How much where the fingers landed favours reading a typed word as another
/// word of the same length.
///
/// Each tap is scored against a 2D Gaussian around every key (σ ≈ a third of
/// a key): an "r" pressed on its right edge is nearly as likely to have been
/// meant as "t" as "r", while one pressed dead centre was meant as "r". The
/// adjustment is in the same units as `TypingCandidates.correctionCost`
/// (edits), negative when the taps favour the candidate, and bounded per
/// letter so position settles close calls rather than overruling spelling.
/// Words of different lengths get no adjustment: their letters do not line
/// up with the taps.
enum TapSpatialScore {
    static let sigma = 0.35
    /// Scales log-likelihood (nats) into edit units: a tap on the shared edge
    /// of two keys is worth nothing either way, one deep in the neighbouring
    /// key about half an edit.
    static let weight = 0.15
    static let perLetterCap = 0.6

    static func adjustment(
        typed: String,
        candidate: String,
        taps: [TapOffset?],
        rows: [String]
    ) -> Double {
        let typedLetters = Array(typed.lowercased())
        let candidateLetters = Array(candidate.lowercased())
        guard typedLetters.count == candidateLetters.count,
              taps.count == typedLetters.count
        else { return 0 }
        let positions = Self.positions(rows: rows)
        var total = 0.0
        for index in typedLetters.indices where typedLetters[index] != candidateLetters[index] {
            guard let tap = taps[index],
                  let pressed = positions[typedLetters[index]],
                  let meant = positions[candidateLetters[index]]
            else { continue }
            // The meant key's centre, relative to the pressed key's.
            let ex = meant.x - pressed.x
            let ey = meant.y - pressed.y
            let toMeant = (tap.dx - ex) * (tap.dx - ex) + (tap.dy - ey) * (tap.dy - ey)
            let toPressed = tap.dx * tap.dx + tap.dy * tap.dy
            let nats = (toMeant - toPressed) / (2 * sigma * sigma)
            total += min(perLetterCap, max(-perLetterCap, weight * nats))
        }
        return total
    }

    /// Key centres in key units, rows staggered as `KeyProximity` staggers them.
    static func positions(rows: [String]) -> [Character: (x: Double, y: Double)] {
        let offsets = KeyProximity.rowOffsets(for: rows)
        var positions: [Character: (x: Double, y: Double)] = [:]
        for (rowIndex, row) in rows.enumerated() {
            let offset = rowIndex < offsets.count ? offsets[rowIndex] : 0
            for (column, character) in row.enumerated() {
                positions[character] = (Double(column) + offset, Double(rowIndex))
            }
        }
        return positions
    }
}
