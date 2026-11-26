import UIKit

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

/// When Shift may touch a selection at all, with the setting on.
///
/// A keyboard replaces a selection with one `insertText`, so whatever it
/// was handed as `selectedText` is everything that survives. The proxy
/// reports no selection range or length to compare that against — a host
/// that hands over less than is selected cannot be caught — so the guard
/// keeps to selections too small for that to happen: one line of at most
/// ``maximumLength`` characters. And never where text is an address rather
/// than prose: a URL, a web search or an email address has no sentence case.
enum SelectionCaseGuard {
    static let maximumLength = 200

    /// Whether this field's text may have its case changed by Shift.
    static func fieldAllows(keyboardType: UIKeyboardType?, contentType: UITextContentType?) -> Bool {
        switch keyboardType {
        case .URL?, .webSearch?, .emailAddress?: return false
        default: break
        }
        if let contentType, [.URL, .emailAddress, .username].contains(contentType) { return false }
        return true
    }

    /// Whether this selection is one Shift may rewrite.
    static func allows(_ selected: String) -> Bool {
        selected.count <= maximumLength
            && selected.contains(where: \.isLetter)
            && !selected.contains(where: \.isNewline)
    }
}

/// How much selected text the edit row's Cut and Copy will take.
///
/// `selectedText` is all a keyboard is told about a selection, while Cut's
/// delete removes the whole selection in the host. A host that reported less
/// than is selected would lose the difference: deleted, and on no clipboard.
/// There is no length to check it against, so long selections are left to
/// the app's own Cut and Copy, which see the real selection.
enum SelectionEditGuard {
    static let maximumLength = ClipboardHistoryPolicy.maximumCharacters

    static func allows(_ selected: String) -> Bool {
        !selected.isEmpty && selected.count <= maximumLength
    }
}
