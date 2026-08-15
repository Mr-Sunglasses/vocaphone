import Testing

/// The rule that decides whether a waiting transcript goes into the field the
/// cursor is in.
///
/// It used to live inside the keyboard controller, where nothing could reach
/// it, and it decided the most-reported behaviour in the product: a dictation
/// that inserts itself, or one that parks behind an Insert button. The
/// controller still owns *when* the target is captured and released; this owns
/// the comparison.
struct InsertionTargetTests {
    @Test func matchingFieldsInsert() {
        #expect(InsertionTarget.allowsInsertion(target: "A", current: "A"))
    }

    /// The case the guard exists for: the cursor moved to another field while
    /// the keyboard was on screen and could see it happen.
    @Test func aDifferentFieldParksTheTranscript() {
        #expect(!InsertionTarget.allowsInsertion(target: "A", current: "B"))
    }

    /// iOS withholds `documentIdentifier` while the keyboard is loading, and on
    /// iOS 26 it can return nil even where the API is declared non-optional. An
    /// unknown identifier is not evidence of a different field, and treating it
    /// as one strands a transcript the user is waiting for.
    @Test func anUnknownIdentifierNeverBlocksInsertion() {
        #expect(InsertionTarget.allowsInsertion(target: nil, current: "A"))
        #expect(InsertionTarget.allowsInsertion(target: "A", current: nil))
        #expect(InsertionTarget.allowsInsertion(target: nil, current: nil))
    }

    /// Releasing the target is what the keyboard does on every appearance, and
    /// it is the whole fix for insertion that worked only sometimes: a session
    /// whose target has been released always inserts into the field the user
    /// has come back to, whether or not iOS kept the extension alive.
    @Test func aReleasedTargetAlwaysAcceptsTheFieldTheUserReturnedTo() {
        let released: String? = nil
        for field in ["A", "B", "the-same-field-with-a-new-identifier"] {
            #expect(InsertionTarget.allowsInsertion(target: released, current: field))
        }
    }
}
