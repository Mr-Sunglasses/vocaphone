import Testing

/// The composer is the keyboard's only answer to "what word is the cursor in".
/// iOS gives an extension no composing region and no way to ask, so if this
/// desynchronises from the document the user watches the wrong word get
/// replaced.
struct WordComposerTests {
    @Test func typingBuildsAWordAndABoundaryEndsIt() {
        var composer = WordComposer()
        composer.insert("h")
        composer.insert("e")
        composer.insert("y")
        #expect(composer.text == "hey")

        composer.insert(" ")
        #expect(composer.isEmpty)
    }

    /// Apostrophes keep a word going, because "don't" is one word to every
    /// spell checker. Hyphens do not, because "well-known" is two.
    @Test func apostrophesStayInsideAWordAndHyphensDoNot() {
        var composer = WordComposer()
        composer.insert("don't")
        #expect(composer.text == "don't")

        composer.reset()
        composer.insert("well-known")
        #expect(composer.text == "known")
    }

    @Test func aMultiCharacterInsertionIsTreatedAsTyping() {
        var composer = WordComposer()
        composer.insert("one two")
        #expect(composer.text == "two")
    }

    @Test func deleteWalksBackThroughTheWordAndStopsAtEmpty() {
        var composer = WordComposer()
        composer.insert("ab")
        composer.deleteBackward()
        #expect(composer.text == "a")
        composer.deleteBackward()
        #expect(composer.isEmpty)
        // An empty composer does not try to reconstruct the previous word from
        // the document window; guessing there is how it desynchronises.
        composer.deleteBackward()
        #expect(composer.isEmpty)
    }

    // MARK: - Origin

    /// Only keystrokes may be autocorrected. A dictated transcript, an accepted
    /// swipe and a tapped suggestion were each chosen by something the user saw.
    @Test func onlyTypedCompositionsAreAutocorrectable() {
        var composer = WordComposer()
        composer.insert("word")
        #expect(composer.isAutocorrectable)

        for origin in [WordComposer.Origin.dictated, .suggestion, .swipe] {
            var adopted = WordComposer()
            adopted.adopt("word", origin: origin)
            #expect(!adopted.isAutocorrectable)
        }
    }

    @Test func anEmptyCompositionIsNeverAutocorrectable() {
        #expect(!WordComposer().isAutocorrectable)
    }

    // MARK: - Reconciliation

    /// The document wins. The user may have moved the cursor with a gesture the
    /// keyboard never saw, and a composition that survives that would rewrite
    /// text somewhere else entirely.
    @Test func theDocumentOverrulesTheComposition() {
        var composer = WordComposer()
        composer.insert("hel")

        composer.reconcile(documentBefore: "say hel")
        #expect(composer.text == "hel")
        #expect(composer.origin == .typed)

        composer.reconcile(documentBefore: "somewhere else")
        #expect(composer.text == "else")
    }

    /// Backspacing past a space puts the keyboard back inside the previous
    /// word. Without this the strip goes quiet for the rest of the sentence the
    /// moment anyone corrects a typo.
    @Test func deletingPastABoundaryRecoversThePreviousWord() {
        var composer = WordComposer()
        composer.insert("hello ")
        #expect(composer.isEmpty)

        composer.deleteBackward()
        composer.reconcile(documentBefore: "hello")
        #expect(composer.text == "hello")
    }

    /// A recovered word may have been dictated — the keyboard knows the letters
    /// but not where they came from — so it is never silently replaced. The
    /// strip still offers the correction as a chip.
    @Test func aRecoveredWordIsNotAutocorrectable() {
        var composer = WordComposer()
        composer.insert("teh")
        composer.reconcile(documentBefore: "said teh")
        #expect(composer.origin == .typed)

        composer.reconcile(documentBefore: "said something")
        #expect(composer.origin == .recovered)
        #expect(!composer.isAutocorrectable)
    }

    /// `nil` means iOS did not answer, which is not the same as an empty
    /// document — the proxy returns `nil` while the keyboard is loading, and
    /// discarding a half-typed word on that is a bug the user sees.
    @Test func aSilentDocumentDoesNotDiscardTheComposition() {
        var composer = WordComposer()
        composer.insert("hel")
        composer.reconcile(documentBefore: nil)
        #expect(composer.text == "hel")
    }

    // MARK: - Rewriting

    @Test func aRewriteDeletesExactlyWhatWasComposed() {
        var composer = WordComposer()
        composer.insert("teh")
        let rewrite = composer.rewrite(to: "the")
        #expect(rewrite.deletions == 3)
        #expect(rewrite.insertion == "the")
    }

    // MARK: - Fuzz

    /// The invariant that actually protects the user: the composer must never
    /// claim more text than the document has.
    ///
    /// A rewrite deletes `composer.text.count` characters. If the composer ever
    /// claimed a longer word than the document holds, those deletions would eat
    /// text the user wrote earlier — the single worst thing this subsystem could
    /// do, and the kind of bug that only shows up after the twentieth keystroke.
    @Test func randomEditSequencesNeverClaimMoreThanTheDocumentHas() {
        var generator = SplitMix64(seed: 0xF00D_BEEF)
        let alphabet = Array("abcde ,.'")

        for _ in 0..<400 {
            var composer = WordComposer()
            var document = ""
            for _ in 0..<40 {
                if generator.next() % 4 == 0, !document.isEmpty {
                    document.removeLast()
                    composer.deleteBackward()
                } else {
                    let character = alphabet[Int(generator.next() % UInt64(alphabet.count))]
                    document.append(character)
                    composer.insert(String(character))
                }
                #expect(document.hasSuffix(composer.text))
            }
        }
    }

    /// And once reconciled — which the engine does after every operation — the
    /// composer agrees with the document exactly. This is what lets the keyboard
    /// keep suggesting after the user backspaces past a space, which a composer
    /// that only ever tracked its own keystrokes could not do.
    @Test func reconcilingAfterEveryEditKeepsTheComposerExact() {
        var generator = SplitMix64(seed: 0x5EED_1234)
        let alphabet = Array("abcde ,.'")

        for _ in 0..<400 {
            var composer = WordComposer()
            var document = ""
            for _ in 0..<40 {
                if generator.next() % 3 == 0, !document.isEmpty {
                    document.removeLast()
                    composer.deleteBackward()
                } else {
                    let character = alphabet[Int(generator.next() % UInt64(alphabet.count))]
                    document.append(character)
                    composer.insert(String(character))
                }
                composer.reconcile(documentBefore: document)
                #expect(composer.text == Self.trailingWord(of: document))
            }
        }
    }

    /// The reference implementation: everything after the last non-word
    /// character. Deliberately written differently from the composer so a shared
    /// mistake cannot pass both.
    private static func trailingWord(of text: String) -> String {
        String(text.reversed().prefix(while: WordComposer.isWordCharacter).reversed())
    }
}

/// A tiny deterministic generator, so a fuzz failure is reproducible rather than
/// something that happened once on someone's machine.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct PrecedingWordTests {
    @Test func theLastWordIsReadThroughTrailingSpace() {
        #expect(PrecedingWord.lastWord(in: "see you ") == "you")
        #expect(PrecedingWord.lastWord(in: "see you") == "you")
        #expect(PrecedingWord.lastWord(in: "see you.") == nil)
        #expect(PrecedingWord.lastWord(in: "") == nil)
        #expect(PrecedingWord.lastWord(in: nil) == nil)
    }

    @Test func aPurelyNumericTailIsNotAWord() {
        #expect(PrecedingWord.lastWord(in: "costs 1200 ") == nil)
    }
}

/// The trailing context, which this subsystem never read.
struct DocumentSnapshotTests {
    /// A cursor at the end of a word is the ordinary case, and everything about
    /// autocorrect depends on it being distinguishable from the other one.
    @Test func aCursorAtTheEndOfAWordIsNotMidWord() {
        #expect(!DocumentSnapshot(before: "hello", after: "").isMidWord)
        #expect(!DocumentSnapshot(before: "hello", after: " world").isMidWord)
        #expect(!DocumentSnapshot(before: "hello", after: ". Next").isMidWord)
    }

    /// Tapping into the middle of "helloworld" after "hello" leaves the composer
    /// holding a prefix of a word it can only see half of. Rewriting that prefix
    /// corrupts a word the user never finished typing.
    @Test func aCursorInsideAWordIsMidWord() {
        #expect(DocumentSnapshot(before: "hello", after: "world").isMidWord)
        #expect(DocumentSnapshot(before: "hel", after: "lo").isMidWord)
        #expect(DocumentSnapshot(before: "don", after: "'t").isMidWord)
    }

    /// iOS answering with nothing is not the same as an empty document. The
    /// permissive reading keeps autocorrect working in fields that decline to
    /// answer, rather than silently switching the feature off there.
    @Test func anUnansweredContextIsNotTreatedAsMidWord() {
        #expect(!DocumentSnapshot.unknown.isMidWord)
        #expect(!DocumentSnapshot(before: "hello").isMidWord)
    }
}
