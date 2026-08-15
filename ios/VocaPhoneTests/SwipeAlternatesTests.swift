import Testing

/// The arithmetic behind replacing a swiped word.
///
/// It is arithmetic at all because the two bugs it replaces were both off by
/// exactly one character: the space a swipe inserts after its word, which the
/// composer cannot see and the replacement therefore never accounted for.
struct SwipeAlternatesTests {
    // MARK: - Armed

    /// The word is still the tail of the document, space and all.
    @Test func aFreshlySwipedWordIsArmed() {
        #expect(SwipeAlternates.isArmed(word: "lol", documentBefore: "haha lol "))
        #expect(SwipeAlternates.isArmed(word: "lol", documentBefore: "lol "))
    }

    /// The trailing space is the whole test. Without it the cursor is inside
    /// the word — the user is editing it, not choosing between spellings — and
    /// with something after it the swipe is no longer what the cursor sits on.
    @Test func anythingTypedAfterTheWordDisarmsIt() {
        #expect(!SwipeAlternates.isArmed(word: "lol", documentBefore: "lol"))
        #expect(!SwipeAlternates.isArmed(word: "lol", documentBefore: "lol x"))
        #expect(!SwipeAlternates.isArmed(word: "lol", documentBefore: "lol  "))
        #expect(!SwipeAlternates.isArmed(word: "lol", documentBefore: "lolly "))
    }

    /// The same word earlier in the sentence is not the swipe. Only the tail
    /// counts, which is what stops a stale strip replacing text somewhere else.
    @Test func anEarlierCopyOfTheWordDoesNotArmIt() {
        #expect(!SwipeAlternates.isArmed(word: "lol", documentBefore: "lol and then "))
    }

    /// iOS can decline to hand over the document, and a replacement that cannot
    /// see what it is replacing must not run.
    @Test func nothingKnownMeansNotArmed() {
        #expect(!SwipeAlternates.isArmed(word: "lol", documentBefore: nil))
        #expect(!SwipeAlternates.isArmed(word: "", documentBefore: "lol "))
    }

    // MARK: - Replacing

    /// The bug, as a number. Deleting `word.count` leaves the rejected word in
    /// the document with the alternate after it — "lol lug " where "lug " was
    /// meant — because the composition the old code measured was empty.
    @Test func aReplacementCoversTheWordAndItsSpace() {
        #expect(SwipeAlternates.deletionCount(replacing: "lol") == 4)
        #expect(SwipeAlternates.deletionCount(replacing: "hello") == 6)
        // Long enough to matter on the word this actually ships against.
        #expect(SwipeAlternates.deletionCount(replacing: "keyboard") == "keyboard ".count)
    }

    // MARK: - What is offered next

    /// The replaced word comes back, first: a swipe corrected once is often
    /// corrected back, and losing the original would make that a retype.
    @Test func theReplacedWordIsOfferedBack() {
        let next = SwipeAlternates.alternates(
            after: "lug",
            replacing: "lol",
            from: ["lug", "log", "lot"]
        )
        #expect(next.first == "lol")
        #expect(next == ["lol", "log", "lot"])
    }

    /// The word now in the document is never offered as a replacement for
    /// itself, whatever case it arrived in.
    @Test func theChosenWordIsNeverOfferedAgain() {
        let next = SwipeAlternates.alternates(
            after: "Lug",
            replacing: "lol",
            from: ["lug", "log"]
        )
        #expect(!next.contains { $0.caseInsensitiveCompare("lug") == .orderedSame })
        #expect(next == ["lol", "log"])
    }

    /// A swipe with one match still offers the way back.
    @Test func aSingleMatchStillOffersTheOriginal() {
        #expect(
            SwipeAlternates.alternates(after: "lug", replacing: "lol", from: [])
                == ["lol"]
        )
    }
}
