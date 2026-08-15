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

enum TextInsertion {
    static func preparedTranscript(
        _ transcript: String,
        before: String?,
        after: String?
    ) -> String {
        var result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        if let last = before?.last,
           !last.isWhitespace,
           !result.first!.isPunctuation {
            result = " " + result
        }

        if let first = after?.first,
           !first.isWhitespace,
           !first.isPunctuation,
           !result.last!.isWhitespace {
            result += " "
        }
        return result
    }
}
