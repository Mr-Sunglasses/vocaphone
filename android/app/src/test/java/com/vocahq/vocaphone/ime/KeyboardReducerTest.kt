package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardReducerTest {

    @Test
    fun `one-shot shift capitalizes one letter`() {
        val shifted = KeyboardState(KeyboardLayer.LETTERS, ShiftState.ONCE)

        val result = KeyboardReducer.press(shifted, character("v"), nowMillis = 1_000)

        assertEquals(KeyboardCommand.CommitText("V"), result.command)
        assertEquals(ShiftState.OFF, result.state.shift)
    }

    @Test
    fun `shift on a selection cycles case instead of arming caps`() {
        val result = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF, composing = "hi"),
            shiftKey(),
            nowMillis = 1_000,
            hasSelection = true,
        )

        assertEquals(KeyboardCommand.CycleSelectionCase, result.command)
        assertEquals(ShiftState.OFF, result.state.shift)
        assertEquals("", result.state.composing)
    }

    @Test
    fun `shift without a selection still notifies the service`() {
        val result = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            shiftKey(),
            nowMillis = 1_000,
        )

        assertEquals(KeyboardCommand.ShiftTap, result.command)
        assertEquals(ShiftState.ONCE, result.state.shift)
    }

    @Test
    fun `double tapping shift enables caps lock`() {
        val first = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            shiftKey(),
            nowMillis = 1_000,
        )
        assertEquals(KeyboardCommand.ShiftTap, first.command)
        val second = KeyboardReducer.press(first.state, shiftKey(), nowMillis = 1_250)
        val letter = KeyboardReducer.press(second.state, character("p"), nowMillis = 1_300)

        assertEquals(ShiftState.LOCKED, second.state.shift)
        assertEquals(KeyboardCommand.CommitText("P"), letter.command)
        assertEquals(ShiftState.LOCKED, letter.state.shift)
    }

    @Test
    fun `sentence punctuation followed by space enables one-shot shift`() {
        val initial = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)
        val punctuation = KeyboardReducer.press(initial, character("."), nowMillis = 1_000)
        val space = KeyboardReducer.press(punctuation.state, spaceKey(), nowMillis = 1_100)

        assertEquals(KeyboardCommand.CommitText(" "), space.command)
        assertEquals(ShiftState.ONCE, space.state.shift)
    }

    @Test
    fun `auto-capitalize off leaves shift alone after a sentence, return, and double space`() {
        val initial = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)
        val punctuation = KeyboardReducer.press(
            initial,
            character("."),
            nowMillis = 1_000,
            autoCapitalize = false,
        )
        val space = KeyboardReducer.press(punctuation.state, spaceKey(), nowMillis = 1_100, autoCapitalize = false)
        val word = KeyboardReducer.press(initial, character("a"), nowMillis = 1_000, autoCapitalize = false)
        val wordSpace = KeyboardReducer.press(word.state, spaceKey(), nowMillis = 1_100, autoCapitalize = false)
        val period = KeyboardReducer.press(wordSpace.state, spaceKey(), nowMillis = 1_200, autoCapitalize = false)
        val enter = KeyboardReducer.press(
            initial,
            KeyboardKey("return", "Enter", type = KeyboardKeyType.RETURN),
            nowMillis = 1_300,
            autoCapitalize = false,
        )

        assertEquals(ShiftState.OFF, space.state.shift)
        assertEquals(KeyboardCommand.DoubleSpacePeriod, period.command)
        assertEquals(ShiftState.OFF, period.state.shift)
        assertEquals(KeyboardCommand.PerformEditorAction, enter.command)
        assertEquals(ShiftState.OFF, enter.state.shift)
    }

    @Test
    fun `auto-capitalize off keeps manual shift and caps lock`() {
        val shifted = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            shiftKey(),
            nowMillis = 1_000,
            autoCapitalize = false,
        )
        val letter = KeyboardReducer.press(shifted.state, character("v"), nowMillis = 1_100, autoCapitalize = false)
        val locked = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.LOCKED),
            KeyboardKey("return", "Enter", type = KeyboardKeyType.RETURN),
            nowMillis = 1_200,
            autoCapitalize = false,
        )

        assertEquals(KeyboardCommand.CommitText("V"), letter.command)
        assertEquals(ShiftState.LOCKED, locked.state.shift)
    }

    @Test
    fun `layer switches change state without writing text`() {
        val result = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.ONCE),
            KeyboardKey(
                id = "numbers",
                label = "?123",
                type = KeyboardKeyType.LAYER_SWITCH,
                targetLayer = KeyboardLayer.NUMBERS,
            ),
            nowMillis = 1_000,
        )

        assertEquals(KeyboardLayer.NUMBERS, result.state.layer)
        assertEquals(ShiftState.OFF, result.state.shift)
        assertNull(result.command)
    }

    @Test
    fun `delete and return produce editor commands`() {
        val state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)

        val delete = KeyboardReducer.press(
            state,
            KeyboardKey("delete", "Delete", type = KeyboardKeyType.DELETE),
            nowMillis = 1_000,
        )
        val enter = KeyboardReducer.press(
            state,
            KeyboardKey("return", "Enter", type = KeyboardKeyType.RETURN),
            nowMillis = 1_000,
        )

        assertEquals(KeyboardCommand.DeleteBackward, delete.command)
        assertEquals(KeyboardCommand.PerformEditorAction, enter.command)
        assertEquals(ShiftState.ONCE, enter.state.shift)
    }

    @Test
    fun `double tapping space inserts a period`() {
        val word = typeWord("hello")
        val afterSpace = KeyboardReducer.press(word, spaceKey(), nowMillis = 1_000)
        val second = KeyboardReducer.press(afterSpace.state, spaceKey(), nowMillis = 1_100)

        assertEquals(KeyboardCommand.DoubleSpacePeriod, second.command)
        assertEquals(ShiftState.ONCE, second.state.shift)
        assertFalse(second.state.lastWasSpace)
        // A third space is a space again.
        val third = KeyboardReducer.press(second.state, spaceKey(), nowMillis = 1_150)
        assertEquals(KeyboardCommand.CommitText(" "), third.command)
    }

    @Test
    fun `double space after punctuation is just two spaces`() {
        // "Hello." + space + space used to make "Hello.. ".
        val stop = KeyboardReducer.press(typeWord("Hello"), character("."), nowMillis = 900)
        val space = KeyboardReducer.press(stop.state, spaceKey(), nowMillis = 1_000)
        val second = KeyboardReducer.press(space.state, spaceKey(), nowMillis = 1_100)
        assertEquals(KeyboardCommand.CommitText(" "), second.command)
        // An empty field too.
        val empty = KeyboardReducer.press(KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF), spaceKey(), nowMillis = 1_000)
        assertEquals(KeyboardCommand.CommitText(" "), KeyboardReducer.press(empty.state, spaceKey(), nowMillis = 1_100).command)
    }

    @Test
    fun `double space needs both spaces within the window, and the setting on`() {
        val afterSpace = KeyboardReducer.press(typeWord("hi"), spaceKey(), nowMillis = 1_000)
        val late = KeyboardReducer.press(
            afterSpace.state,
            spaceKey(),
            nowMillis = 1_000 + KeyboardReducer.DOUBLE_SPACE_WINDOW_MILLIS + 1,
        )
        assertEquals(KeyboardCommand.CommitText(" "), late.command)
        val off = KeyboardReducer.press(afterSpace.state, spaceKey(), nowMillis = 1_100, doubleSpacePeriod = false)
        assertEquals(KeyboardCommand.CommitText(" "), off.command)
        // After a digit it still closes the sentence.
        val digit = KeyboardReducer.press(KeyboardState(KeyboardLayer.NUMBERS, ShiftState.OFF), character("3"), nowMillis = 900)
        val digitSpace = KeyboardReducer.press(digit.state, spaceKey(), nowMillis = 1_000)
        assertEquals(KeyboardCommand.DoubleSpacePeriod, KeyboardReducer.press(digitSpace.state, spaceKey(), nowMillis = 1_100).command)
    }

    @Test
    fun `a word picked from the strip can be closed with a double space`() {
        val picked = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF).afterWordAndSpace(1_000)
        assertEquals(KeyboardCommand.DoubleSpacePeriod, KeyboardReducer.press(picked, spaceKey(), nowMillis = 1_200).command)
    }

    @Test
    fun `no capital after an abbreviation or a list number`() {
        for (typed in listOf("e.g", "Mr", "vs", "etc", "3", "(i.e")) {
            var state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)
            for (character in typed) {
                state = KeyboardReducer.press(state, character(character.toString()), nowMillis = 1_000, composeWords = true).state
            }
            val stop = KeyboardReducer.press(state, character("."), nowMillis = 1_000, composeWords = true)
            val space = KeyboardReducer.press(stop.state, spaceKey(), nowMillis = 1_100)
            assertEquals(typed, ShiftState.OFF, space.state.shift)
        }
        val sentence = KeyboardReducer.press(typeWord("done"), character("."), nowMillis = 1_000)
        assertEquals(ShiftState.ONCE, KeyboardReducer.press(sentence.state, spaceKey(), nowMillis = 1_100).state.shift)
        val question = KeyboardReducer.press(typeWord("Mr"), character("?"), nowMillis = 1_000)
        assertEquals(ShiftState.ONCE, KeyboardReducer.press(question.state, spaceKey(), nowMillis = 1_100).state.shift)
    }

    @Test
    fun `sentence boundary knows an abbreviation from a full stop`() {
        assertTrue(SentenceBoundary.endsSentence(""))
        assertTrue(SentenceBoundary.endsSentence("Done. "))
        assertTrue(SentenceBoundary.endsSentence("Really? "))
        assertTrue(SentenceBoundary.endsSentence("line\n"))
        assertFalse(SentenceBoundary.endsSentence("see e.g. "))
        assertFalse(SentenceBoundary.endsSentence("Mr. "))
        assertFalse(SentenceBoundary.endsSentence("3. "))
        assertFalse(SentenceBoundary.endsSentence("hello "))
        assertFalse(SentenceBoundary.endsSentence("hello"))
    }

    private fun typeWord(word: String): KeyboardState {
        var state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)
        for (character in word) {
            state = KeyboardReducer.press(state, character(character.toString()), nowMillis = 500, composeWords = true).state
        }
        return state
    }

    @Test
    fun `letter keys compose when suggestions are on`() {
        val first = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            character("h"),
            nowMillis = 1_000,
            composeWords = true,
        )
        val second = KeyboardReducer.press(first.state, character("i"), nowMillis = 1_010, composeWords = true)

        assertEquals(KeyboardCommand.SetComposingText("h"), first.command)
        assertEquals(KeyboardCommand.SetComposingText("hi"), second.command)
        assertEquals("hi", second.state.composing)
    }

    @Test
    fun `undo last composing letter drops one character`() {
        val first = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            character("h"),
            nowMillis = 1_000,
            composeWords = true,
        )
        val second = KeyboardReducer.press(
            first.state,
            character("i"),
            nowMillis = 1_010,
            composeWords = true,
        )

        val undo = KeyboardReducer.undoLastCharacter(second.state, composeWords = true)

        assertEquals(KeyboardCommand.SetComposingText("h"), undo.command)
        assertEquals("h", undo.state.composing)
    }

    @Test
    fun `a sentence-start letter stays capitalized unless the seed is undone`() {
        val afterStop = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            character("."),
            nowMillis = 1_000,
        )
        val spaced = KeyboardReducer.press(afterStop.state, spaceKey(), nowMillis = 1_100)
        assertEquals(ShiftState.ONCE, spaced.state.shift)

        val letter = KeyboardReducer.press(
            spaced.state,
            character("h"),
            nowMillis = 1_200,
            composeWords = true,
        )
        assertEquals("H", letter.state.composing)
        assertEquals(ShiftState.OFF, letter.state.shift)
    }

    @Test
    fun `undo of the first letter restores one-shot shift`() {
        val typed = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.ONCE),
            character("h"),
            nowMillis = 1_000,
            composeWords = true,
        )
        assertEquals(ShiftState.OFF, typed.state.shift)

        val undo = KeyboardReducer.undoLastCharacter(
            typed.state,
            composeWords = true,
            restoreShift = ShiftState.ONCE,
        )

        assertEquals(ShiftState.ONCE, undo.state.shift)
        assertEquals("", undo.state.composing)
        assertEquals(KeyboardCommand.SetComposingText(""), undo.command)
    }

    @Test
    fun `undo last committed letter deletes surrounding`() {
        val typed = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            character("h"),
            nowMillis = 1_000,
            composeWords = false,
        )

        val undo = KeyboardReducer.undoLastCharacter(typed.state, composeWords = false)

        assertEquals(KeyboardCommand.DeleteSurrounding(1, 0), undo.command)
    }

    @Test
    fun `long-press on a digit replaces it in one batch`() {
        val typed = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            character("2"),
            nowMillis = 1_000,
            composeWords = true,
        )
        assertEquals(KeyboardCommand.CommitText("2"), typed.command)
        assertEquals("", typed.state.composing)

        val replaced = KeyboardReducer.replaceLastCharacter(
            typed.state,
            replacement = "@",
            composeWords = true,
        )
        assertEquals(KeyboardCommand.ReplaceLastCommitted("@"), replaced.command)
        assertEquals("", replaced.state.composing)
    }

    @Test
    fun `long-press on a composing letter rewrites the composing word`() {
        val typed = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            character("e"),
            nowMillis = 1_000,
            composeWords = true,
        )
        assertEquals(KeyboardCommand.SetComposingText("e"), typed.command)

        val replaced = KeyboardReducer.replaceLastCharacter(
            typed.state,
            replacement = "é",
            composeWords = true,
        )
        assertEquals(KeyboardCommand.SetComposingText("é"), replaced.command)
        assertEquals("é", replaced.state.composing)
    }

    @Test
    fun `long-press on a composing letter for a symbol replaces in one batch`() {
        val typed = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            character("a"),
            nowMillis = 1_000,
            composeWords = true,
        )
        assertEquals(KeyboardCommand.SetComposingText("a"), typed.command)

        val replaced = KeyboardReducer.replaceLastCharacter(
            typed.state,
            replacement = "@",
            composeWords = true,
        )
        assertEquals(KeyboardCommand.ReplaceLastCommitted("@"), replaced.command)
        assertEquals("", replaced.state.composing)
    }

    @Test
    fun `delete while composing shortens the composing word`() {
        val typed = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF, composing = "hi"),
            KeyboardKey("delete", "Delete", type = KeyboardKeyType.DELETE),
            nowMillis = 1_000,
            composeWords = true,
        )

        assertEquals(KeyboardCommand.SetComposingText("h"), typed.command)
        assertEquals("h", typed.state.composing)
    }

    private fun character(value: String) = KeyboardKey(
        id = "character-$value",
        label = value,
        output = value,
    )

    private fun shiftKey() = KeyboardKey(
        id = "shift",
        label = "Shift",
        type = KeyboardKeyType.SHIFT,
    )

    private fun spaceKey() = KeyboardKey(
        id = "space",
        label = "Space",
        type = KeyboardKeyType.SPACE,
    )
}
