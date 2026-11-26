import Foundation

/// Shift on a selection: Sentence case → ALL CAPS → lower → the original.
///
/// The Android keyboard's `CaseCycle`, with the same three derived forms and
/// the same rule for a fourth: a mixed spelling such as "iPhone" is none of
/// them, so it comes back after lower instead of being lost to the first tap.
/// "Title" here is the first word capitalised and the rest lowered, which is
/// what Android does and what a sentence wants.
///
/// Pure, so the cycle is tested without a text field.
enum CaseCycle {
    /// The spelling after `text`, given where the cycle started. Text with no
    /// letters has nothing to cycle and comes back unchanged.
    static func next(_ text: String, original: String? = nil) -> String {
        guard text.contains(where: \.isLetter) else { return text }
        let original = original ?? text
        var options: [String] = []
        for option in [sentence(text), text.uppercased(), text.lowercased(), original]
        where !options.contains(option) {
            options.append(option)
        }
        guard let index = options.firstIndex(of: text) else { return options[0] }
        return options[(index + 1) % options.count]
    }

    /// The first word capitalised, every other word lowered. Words are runs
    /// of letters, digits and apostrophes, so "don't" stays one word.
    static func sentence(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var wordIndex = 0
        var inWord = false
        var capitalisedInWord = false
        for character in text {
            let isWordCharacter = character.isLetter || character.isNumber || character == "'"
                || character == "\u{2019}"
            if isWordCharacter {
                if !inWord {
                    inWord = true
                    capitalisedInWord = false
                }
                if wordIndex == 0, !capitalisedInWord, character.isLetter {
                    result += character.uppercased()
                    capitalisedInWord = true
                } else {
                    result += character.lowercased()
                }
            } else {
                if inWord { wordIndex += 1 }
                inWord = false
                result.append(character)
            }
        }
        return result
    }
}

/// A case cycle in progress, so the next Shift can carry on from it.
///
/// A keyboard extension can replace a selection but cannot select anything:
/// `UITextDocumentProxy` has no way to set one. After the first tap the
/// selection is gone and the new spelling sits just before the cursor, so
/// that is what the next tap looks for. If the cursor has moved, or anything
/// else has been typed, the cycle is over — deleting by count where the text
/// is no longer the text would delete somebody else's words.
struct CaseCycleSession: Equatable {
    /// The spelling the cycle started from, which it returns to.
    let original: String
    /// What the last step inserted.
    let emitted: String
    /// The text after the cursor when it was inserted.
    let after: String?

    /// Selections longer than this are cycled once and not carried on: the
    /// carry-on deletes the text a character at a time.
    static let continuationLimit = 400

    /// Whether `document` still ends in the last step, with nothing moved.
    func continues(before: String?, after: String?) -> Bool {
        guard emitted.count <= Self.continuationLimit,
              let before, before.hasSuffix(emitted),
              after == self.after
        else { return false }
        return true
    }
}
