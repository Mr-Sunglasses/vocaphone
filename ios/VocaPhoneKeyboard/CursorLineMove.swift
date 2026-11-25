import Foundation

/// Where the trackpad's up and down movement puts the cursor.
///
/// A keyboard can only move the cursor by an offset, and no field says where
/// it wraps, so the text the field shares is laid out here as rows: a new row
/// at every newline and every `charactersPerRow` characters (an estimate of a
/// full-width field's line). Moving up or down keeps the column, clamped to
/// the target row's length, and stops at the first and last row of the text
/// the field shared.
enum CursorLineMove {
    /// The UTF-16 offset that moves the cursor at `position` (a UTF-16 index
    /// into `text`) by `lines` rows, negative for up. Zero when it cannot move.
    static func offset(text: String, position: Int, lines: Int, charactersPerRow: Int) -> Int {
        guard lines != 0, charactersPerRow > 0 else { return 0 }
        let characters = Array(text)
        // UTF-16 index of every character boundary, so offsets stay in the
        // proxy's units while rows are counted in characters.
        var boundaries: [Int] = [0]
        boundaries.reserveCapacity(characters.count + 1)
        for character in characters { boundaries.append(boundaries.last! + character.utf16.count) }
        guard let cursor = boundaries.firstIndex(where: { $0 >= position }) else { return 0 }

        // Each row as a range of character indices, the newline ending it
        // excluded.
        var rows: [Range<Int>] = []
        var start = 0
        var column = 0
        for (index, character) in characters.enumerated() {
            if character.isNewline {
                rows.append(start..<index)
                start = index + 1
                column = 0
            } else if column == charactersPerRow {
                rows.append(start..<index)
                start = index
                column = 1
            } else {
                column += 1
            }
        }
        rows.append(start..<characters.count)

        guard let row = rows.lastIndex(where: { $0.lowerBound <= cursor }) else { return 0 }
        let target = min(max(row + lines, 0), rows.count - 1)
        guard target != row else { return 0 }
        let wantedColumn = cursor - rows[row].lowerBound
        let landing = rows[target].lowerBound + min(wantedColumn, rows[target].count)
        return boundaries[landing] - boundaries[cursor]
    }
}
