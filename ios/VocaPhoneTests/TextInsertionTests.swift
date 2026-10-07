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

    @Test func undoFindsAShortInsertionAtTheCursor() {
        #expect(InsertionUndo.isAtCursor(
            " hello world", following: "", before: "Say hello world", after: ""
        ))
    }

    /// iOS shows a keyboard a bounded window before the cursor. A long
    /// dictation never fits in it, and Undo failed every time with "The
    /// cursor moved".
    @Test func undoFindsALongInsertionThroughABoundedWindow() {
        let sentence = "This is one of many sentences in a long dictation. "
        let inserted = " " + String(repeating: sentence, count: 12) + "The end."
        let window = String(("Earlier text." + inserted).suffix(80))
        #expect(InsertionUndo.isAtCursor(inserted, following: nil, before: window, after: nil))
        // A window cut at the last paragraph break.
        let paragraphs = " First paragraph of it.\nSecond and last."
        #expect(InsertionUndo.isAtCursor(
            paragraphs, following: "", before: "Second and last.", after: ""
        ))
    }

    @Test func undoRefusesOnceTheCursorHasMoved() {
        let inserted = " hello world"
        #expect(!InsertionUndo.isAtCursor(inserted, following: "", before: "Say hello", after: " world"))
        #expect(!InsertionUndo.isAtCursor(inserted, following: "", before: "Something else", after: ""))
        #expect(!InsertionUndo.isAtCursor(inserted, following: "", before: "", after: ""))
        #expect(!InsertionUndo.isAtCursor(inserted, following: "", before: nil, after: ""))
        // Same text before the cursor, different text after it: the cursor is
        // somewhere else that happens to end the same way.
        #expect(!InsertionUndo.isAtCursor(inserted, following: "", before: "Say hello world", after: "!"))
        #expect(!InsertionUndo.isAtCursor(
            inserted, following: " and more", before: "Say hello world", after: ""
        ))
    }

    /// Typing after the insertion detaches it, even when the window is short.
    @Test func undoRefusesAWindowThatIsNotTheInsertionsTail() {
        let inserted = " " + String(repeating: "word ", count: 40) + "end."
        #expect(!InsertionUndo.isAtCursor(inserted, following: "", before: "end.x", after: ""))
        #expect(!InsertionUndo.isAtCursor(inserted, following: "", before: "typed", after: ""))
    }

    @Test func anUnansweredFollowingContextMatchesAnEmptyOne() {
        #expect(InsertionUndo.isAtCursor(" hi", following: nil, before: "Say hi", after: ""))
        #expect(InsertionUndo.isAtCursor(" hi", following: "", before: "Say hi", after: nil))
    }
}
