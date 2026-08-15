import Foundation

/// The word a swipe just committed, and the ones that lost to it.
///
/// A swiped word is not a composition. It arrives whole, with the space that
/// follows it already in the document, and that is precisely what
/// ``WordComposer`` cannot represent: the composer describes the word the
/// cursor is *inside*, and after a swipe the cursor is past a space, so the
/// composition is correctly empty. Two things went wrong when the alternates
/// were hung off the composer anyway:
///
/// * The alternates were published and then wiped by the reconcile that the
///   swipe's own insertion triggers, so they flashed and vanished.
/// * Replacing one deleted `composer.text.count` characters — zero, by then —
///   and inserted the alternate after the word instead of over it.
///
/// So the swipe keeps its own state, and this is the arithmetic behind it:
/// whether the word is still there to replace, how much of the document that
/// replacement covers, and what to offer once it has happened.
enum SwipeAlternates {
    /// Whether the swiped word is still exactly what sits before the cursor.
    ///
    /// The trailing space is part of the test, not an afterthought. It is what
    /// distinguishes a word the swipe just placed from the same word typed
    /// earlier in the sentence, and it is the character a replacement has to
    /// account for.
    static func isArmed(word: String, documentBefore: String?) -> Bool {
        guard !word.isEmpty, let documentBefore else { return false }
        return documentBefore.hasSuffix(word + " ")
    }

    /// The word plus the space the swipe put after it. Deleting one character
    /// fewer is what left "lol lug " where "lug " was meant.
    static func deletionCount(replacing word: String) -> Int {
        word.count + 1
    }

    /// What to offer after `chosen` replaces `word`.
    ///
    /// The replaced word goes back on the strip, first: a swipe that guessed
    /// wrong is usually corrected in one tap, and the tap after that is often
    /// "no, the original". Losing it would make the second correction a
    /// retype.
    static func alternates(
        after chosen: String,
        replacing word: String,
        from alternates: [String]
    ) -> [String] {
        ([word] + alternates).filter {
            $0.caseInsensitiveCompare(chosen) != .orderedSame
        }
    }
}
