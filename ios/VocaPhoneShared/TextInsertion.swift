import Foundation

/// Whether a waiting transcript may go into the field the cursor is in.
///
/// The rule is about *evidence*, not about identifiers. A keyboard extension
/// can watch the cursor move while it is on screen; it can see nothing at all
/// while it is off screen, and iOS reissues document identifiers across an app
/// switch and across a relaunch of the extension. Treating a reissued
/// identifier as "a different field" is how a transcript ends up stranded
/// behind an Insert button in the very field it was dictated for.
///
/// So the target is only compared within one appearance of the keyboard, and a
/// missing identifier on either side never blocks: a transcript the user is
/// waiting for must not be held hostage by something iOS declined to tell us.
enum InsertionTarget {
    static func allowsInsertion(target: String?, current: String?) -> Bool {
        guard let target, let current else { return true }
        return target == current
    }
}

/// A transcript ready to go into the document, and how to get it there.
struct PreparedInsertion: Equatable {
    /// UTF-16 units to move the cursor forward first — the unit
    /// `adjustTextPosition(byCharacterOffset:)` steps in. Non-zero only when
    /// the cursor sat inside a word: the transcript goes after the word rather
    /// than through the middle of it.
    var cursorAdvance: Int
    /// The text to insert, with whatever spacing it needs on either side.
    var text: String
    /// What the document holds after the cursor once the text is in. Undo
    /// compares against it to tell that the cursor has not moved.
    var following: String?
}

enum TextInsertion {
    static func preparedTranscript(
        _ transcript: String,
        before: String?,
        after: String?
    ) -> String {
        prepare(transcript, before: before, after: after).text
    }

    /// Places a transcript at the cursor without splitting a word or crowding
    /// the text around it.
    ///
    /// The cursor inside a word — "hel|lo" — used to produce "hel world lo".
    /// Dictating into the middle of a word is never what anyone meant; the
    /// cursor got there by a tap that landed a few points off. The transcript
    /// now goes after the word. A selection is left alone: inserting replaces
    /// it, which is what selecting text and dictating asks for.
    ///
    /// Spacing follows the characters either side, as it always did, with one
    /// refinement: opening brackets and quotes hold on to what follows them, so
    /// "(" + "note" is "(note", and "said" + "“hi”" is "said “hi”".
    static func prepare(
        _ transcript: String,
        before: String?,
        after: String?,
        hasSelection: Bool = false
    ) -> PreparedInsertion {
        var result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstCharacter = result.first, let lastCharacter = result.last else {
            return PreparedInsertion(cursorAdvance: 0, text: result, following: after)
        }

        var preceding = before?.last
        var following = after
        var cursorAdvance = 0
        if !hasSelection, let previous = preceding, isSpacedWordCharacter(previous), let after {
            let word = wordPrefix(of: after)
            if let end = word.last {
                cursorAdvance = word.utf16.count
                preceding = end
                following = String(after.dropFirst(word.count))
            }
        }

        if let previous = preceding,
           !previous.isWhitespace,
           !opensGroup(previous),
           !attachesToPrevious(firstCharacter),
           usesSpaces(previous), usesSpaces(firstCharacter)
        {
            result = " " + result
        }

        if let next = following?.first,
           !next.isWhitespace,
           !attachesToPrevious(next),
           !lastCharacter.isWhitespace,
           !opensGroup(lastCharacter),
           usesSpaces(next), usesSpaces(lastCharacter)
        {
            result += " "
        }
        return PreparedInsertion(cursorAdvance: cursorAdvance, text: result, following: following)
    }

    /// Part of a word: letters and digits in any script. A Swift `Character`
    /// is a whole grapheme, so an accent or an emoji modifier never splits one.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// A word character in a script that separates words with spaces. In
    /// Chinese, Japanese or Thai a run of letters is a clause, not a word, and
    /// jumping to its end would move the transcript a sentence away.
    private static func isSpacedWordCharacter(_ character: Character) -> Bool {
        isWordCharacter(character) && usesSpaces(character)
    }

    /// Whether the character's script puts spaces between words. Those that do
    /// not get no space added beside them either: "你好" + "世界" is "你好世界".
    private static func usesSpaces(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return true }
        let unspaced: [ClosedRange<UInt32>] = [
            0x0E00...0x0EFF, // Thai, Lao
            0x1000...0x109F, // Myanmar
            0x1780...0x17FF, // Khmer
            0x3040...0x30FF, // Hiragana, Katakana
            0x3100...0x312F, // Bopomofo
            0x31F0...0x31FF, // Katakana extensions
            0x3400...0x4DBF, // CJK extension A
            0x4E00...0x9FFF, // CJK unified ideographs
            0xF900...0xFAFF, // CJK compatibility ideographs
            0xFF66...0xFF9F, // Half-width katakana
            0x20000...0x3134F, // CJK extensions B onward
        ]
        return !unspaced.contains { $0.contains(value) }
    }

    /// The rest of the word the cursor is in. An apostrophe between letters
    /// belongs to the word, so "do|n't" finishes as "don't".
    private static func wordPrefix(of text: String) -> Substring {
        var end = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if isSpacedWordCharacter(character) {
                end = next
            } else if character == "'" || character == "’",
                      next < text.endIndex, isSpacedWordCharacter(text[next]) {
                // Kept only if a letter follows; the loop takes that next.
            } else {
                break
            }
            index = next
        }
        return text[text.startIndex..<end]
    }

    /// "(", "[", "“", "¿" and the like: the text after them belongs to them.
    private static func opensGroup(_ character: Character) -> Bool {
        guard let category = character.unicodeScalars.first?.properties.generalCategory
        else { return false }
        return category == .openPunctuation || category == .initialPunctuation
            || character == "¿" || character == "¡"
    }

    /// Punctuation that hangs on the word before it — ".", ",", ")", "”".
    private static func attachesToPrevious(_ character: Character) -> Bool {
        character.isPunctuation && !opensGroup(character)
    }
}

/// Whether the transcript just inserted is still exactly where the cursor is,
/// so Undo can remove it without touching anything else.
///
/// iOS hands a keyboard a bounded window onto the document — often only the
/// current sentence or paragraph — so a long dictation is never wholly visible
/// in `documentContextBeforeInput`. Requiring the whole insertion there made
/// Undo fail on every long dictation with "The cursor moved". The window is
/// compared against the insertion's tail instead, and the text after the cursor
/// must be what it was when the insertion was made — the evidence that the
/// cursor has not moved somewhere that happens to end the same way.
enum InsertionUndo {
    static func isAtCursor(
        _ inserted: String,
        following: String?,
        before: String?,
        after: String?
    ) -> Bool {
        guard !inserted.isEmpty, let before, !before.isEmpty else { return false }
        guard (after ?? "") == (following ?? "") else { return false }
        if before.hasSuffix(inserted) { return true }
        // A window shorter than the insertion can only be the insertion's tail.
        return before.count < inserted.count && inserted.hasSuffix(before)
    }
}
