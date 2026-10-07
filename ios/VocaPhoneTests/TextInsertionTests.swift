import Testing

/// Where a finished transcript lands relative to the text around the cursor,
/// and whether Undo can still find it.
struct TextInsertionTests {
    private func prepare(
        _ transcript: String,
        before: String?,
        after: String?,
        hasSelection: Bool = false
    ) -> PreparedInsertion {
        TextInsertion.prepare(transcript, before: before, after: after, hasSelection: hasSelection)
    }

    // MARK: - Word boundaries

    /// "hel|lo" + "world" used to be "hel world lo".
    @Test func aCursorInsideAWordInsertsAfterTheWord() {
        let prepared = prepare("world", before: "Say hel", after: "lo there")
        #expect(prepared.cursorAdvance == 2)
        #expect(prepared.text == " world")
        #expect(prepared.following == " there")
    }

    @Test func aCursorInsideTheLastWordInsertsAtTheEnd() {
        let prepared = prepare("world", before: "hel", after: "lo")
        #expect(prepared.cursorAdvance == 2)
        #expect(prepared.text == " world")
        #expect(prepared.following == "")
    }

    @Test func anApostropheBetweenLettersIsPartOfTheWord() {
        let prepared = prepare("stop", before: "do", after: "n't go")
        #expect(prepared.cursorAdvance == 3)
        #expect(prepared.text == " stop")
        #expect(prepared.following == " go")
    }

    /// Just after the apostrophe is still inside the contraction: "don'|t"
    /// used to become "don' stop t go".
    @Test func aCursorJustAfterAnApostropheFinishesTheContraction() {
        let prepared = prepare("stop", before: "don'", after: "t go")
        #expect(prepared.cursorAdvance == 1)
        #expect(prepared.text == " stop")
        #expect(prepared.following == " go")
        #expect(prepare("stop", before: "don’", after: "t go").cursorAdvance == 1)
        // A closing quote is not a contraction.
        #expect(prepare("stop", before: "said 'hi'", after: " then").cursorAdvance == 0)
        #expect(prepare("stop", before: "'", after: "t go").cursorAdvance == 0)
    }

    /// The advance is in UTF-16 units, the unit the proxy moves in, while the
    /// word is found by grapheme so a combining accent is never split off.
    @Test func theAdvanceIsCountedInUTF16Units() {
        let prepared = prepare("noir", before: "caf", after: "e\u{301} au lait")
        #expect(prepared.cursorAdvance == 2)
        #expect(prepared.following == " au lait")

        let astral = prepare("x", before: "a", after: "𝒜b c")
        #expect(astral.cursorAdvance == 3)
        #expect(astral.following == " c")
    }

    @Test func aCursorBetweenWordsDoesNotMove() {
        #expect(prepare("world", before: "hello ", after: "there").cursorAdvance == 0)
        #expect(prepare("world", before: "hello", after: " there").cursorAdvance == 0)
        #expect(prepare("world", before: nil, after: "there").cursorAdvance == 0)
        #expect(prepare("world", before: "hello", after: nil).cursorAdvance == 0)
    }

    /// Selecting text and dictating replaces the selection; moving the cursor
    /// first would collapse it and insert beside it instead.
    @Test func aSelectionIsReplacedWhereItIs() {
        let prepared = prepare("world", before: "say ", after: " there", hasSelection: true)
        #expect(prepared.cursorAdvance == 0)
        #expect(prepared.text == "world")

        let midWord = prepare("x", before: "un", after: "able", hasSelection: true)
        #expect(midWord.cursorAdvance == 0)
    }

    /// In scripts without spaces between words a run of letters is a clause,
    /// and none of it should be skipped or padded.
    @Test func scriptsWithoutSpacesAreNeitherSkippedNorPadded() {
        let chinese = prepare("再见", before: "你好", after: "世界")
        #expect(chinese.cursorAdvance == 0)
        #expect(chinese.text == "再见")
        #expect(prepare("ありがとう", before: "こんにちは", after: nil).text == "ありがとう")
    }

    // MARK: - Spacing

    @Test func afterPunctuationTheTranscriptStartsAWord() {
        #expect(prepare("world", before: "Hello.", after: nil).text == " world")
        #expect(prepare("world", before: "Hello,", after: "").text == " world")
        #expect(prepare("world", before: "Hello!", after: nil).cursorAdvance == 0)
    }

    @Test func openingBracketsAndQuotesHoldOnToWhatFollows() {
        #expect(prepare("note", before: "(", after: ")").text == "note")
        #expect(prepare("note", before: "see “", after: "”").text == "note")
        #expect(prepare("¿qué?", before: "Dijo", after: nil).text == " ¿qué?")
        #expect(prepare("“hi”", before: "said", after: nil).text == " “hi”")
    }

    @Test func closingPunctuationHangsOnTheWordBeforeIt() {
        #expect(prepare(",", before: "hello", after: " world").text == ",")
        #expect(prepare("world", before: "hello ", after: ".").text == "world")
        #expect(prepare("world", before: "hello ", after: ")").text == "world")
    }

    /// An emoji is a whole grapheme, however many scalars it takes, and it is
    /// spaced like a word rather than split or treated as punctuation.
    @Test func emojiAreSpacedAsWholeCharacters() {
        #expect(prepare("great", before: "👍🏽", after: nil).text == " great")
        let family = prepare("world", before: "hi", after: "👨‍👩‍👧 there")
        #expect(family.cursorAdvance == 0)
        #expect(family.text == " world ")
        let suffix = prepare("x", before: "ab", after: "c👍🏽 d")
        #expect(suffix.cursorAdvance == 1)
        #expect(suffix.following == "👍🏽 d")
    }

    @Test func whitespaceOnlyTranscriptsInsertNothing() {
        #expect(prepare("  \n", before: "hel", after: "lo").text == "")
        #expect(prepare("  \n", before: "hel", after: "lo").cursorAdvance == 0)
    }

    // MARK: - Undo

    private func undoable(
        _ inserted: String,
        following: String?,
        before: String?,
        after: String?,
        insertedIn documentID: String? = "doc",
        now currentDocumentID: String? = "doc"
    ) -> Bool {
        InsertionUndo.isAtCursor(
            inserted,
            following: following,
            documentID: documentID,
            before: before,
            after: after,
            currentDocumentID: currentDocumentID
        )
    }

    @Test func undoFindsAShortInsertionAtTheCursor() {
        #expect(undoable(" hello world", following: "", before: "Say hello world", after: ""))
        // iOS does not always name the document; the whole insertion in view
        // is evidence enough.
        #expect(undoable(
            " hello world", following: "", before: "Say hello world", after: "",
            insertedIn: nil, now: nil
        ))
    }

    /// iOS shows a keyboard a bounded window before the cursor. A long
    /// dictation never fits in it, and Undo failed every time with "The
    /// cursor moved".
    @Test func undoFindsALongInsertionThroughABoundedWindow() {
        let sentence = "This is one of many sentences in a long dictation. "
        let inserted = " " + String(repeating: sentence, count: 12) + "The end."
        let window = String(("Earlier text." + inserted).suffix(80))
        #expect(undoable(inserted, following: nil, before: window, after: nil))
        // A window cut at the last paragraph break.
        let paragraphs = " First paragraph of it.\nSecond and last paragraph of the dictation."
        #expect(undoable(
            paragraphs, following: "", before: "Second and last paragraph of the dictation.", after: ""
        ))
    }

    @Test func undoRefusesOnceTheCursorHasMoved() {
        let inserted = " hello world"
        #expect(!undoable(inserted, following: "", before: "Say hello", after: " world"))
        #expect(!undoable(inserted, following: "", before: "Something else", after: ""))
        #expect(!undoable(inserted, following: "", before: "", after: ""))
        #expect(!undoable(inserted, following: "", before: nil, after: ""))
        // Same text before the cursor, different text after it: the cursor is
        // somewhere else that happens to end the same way.
        #expect(!undoable(inserted, following: "", before: "Say hello world", after: "!"))
        #expect(!undoable(inserted, following: " and more", before: "Say hello world", after: ""))
        // Another field that iOS says is another field.
        #expect(!undoable(
            inserted, following: "", before: "Say hello world", after: "", now: "other"
        ))
    }

    /// Typing after the insertion detaches it, even when the window is short.
    @Test func undoRefusesAWindowThatIsNotTheInsertionsTail() {
        let inserted = " " + String(repeating: "word ", count: 40) + "end."
        #expect(!undoable(inserted, following: "", before: "end.x", after: ""))
        #expect(!undoable(inserted, following: "", before: "typed", after: ""))
    }

    /// A window that shows only the tail is weaker evidence, and Undo deletes
    /// the insertion's full length. Another paragraph or field that ends the
    /// same way must not lose its text: the tail only counts in the document
    /// the insertion went into, and only when it is long enough to mean
    /// something.
    @Test func undoRefusesATailItCannotTieToThisInsertion() {
        let sentence = "This is one of many sentences in a long dictation. "
        let inserted = " " + String(repeating: sentence, count: 12) + "Thanks."
        let window = String(inserted.suffix(80))
        // Another field, or one iOS will not name.
        #expect(!undoable(inserted, following: "", before: window, after: "", now: "other"))
        #expect(!undoable(inserted, following: "", before: window, after: "", now: nil))
        #expect(!undoable(inserted, following: "", before: window, after: "", insertedIn: nil))
        // A sentence-bounded window that half the paragraphs in a note end with.
        #expect(!undoable(inserted, following: "", before: "Thanks.", after: ""))
        #expect(undoable(inserted, following: "", before: window, after: ""))
    }

    /// The stored following text was cut from the window read before the
    /// insertion. A host that bounds the window by length shows more of the
    /// document once the cursor has stepped past a word, and that is still the
    /// same place.
    @Test func undoAcceptsAFollowingWindowThatShowsMoreOfTheSameText() {
        let prepared = prepare("world", before: "Say hel", after: "lo there and")
        let inserted = prepared.text
        #expect(undoable(
            inserted, following: prepared.following,
            before: "Say hello world", after: " there and more"
        ))
        // But not one that has lost text, or an empty one.
        #expect(!undoable(inserted, following: prepared.following, before: "Say hello world", after: " the"))
        #expect(!undoable(inserted, following: prepared.following, before: "Say hello world", after: ""))
    }

    @Test func anUnansweredFollowingContextMatchesAnEmptyOne() {
        #expect(undoable(" hi", following: nil, before: "Say hi", after: ""))
        #expect(undoable(" hi", following: "", before: "Say hi", after: nil))
    }
}
