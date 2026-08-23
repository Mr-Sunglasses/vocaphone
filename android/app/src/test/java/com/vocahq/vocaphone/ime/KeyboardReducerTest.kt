package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
        val afterSpace = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            spaceKey(),
            nowMillis = 1_000,
        )
        val second = KeyboardReducer.press(afterSpace.state, spaceKey(), nowMillis = 1_100)

        assertEquals(KeyboardCommand.DoubleSpacePeriod, second.command)
        assertEquals(ShiftState.ONCE, second.state.shift)
        assertFalse(second.state.lastWasSpace)
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
    fun `undo last committed letter deletes backward`() {
        val typed = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            character("h"),
            nowMillis = 1_000,
            composeWords = false,
        )

        val undo = KeyboardReducer.undoLastCharacter(typed.state, composeWords = false)

        assertEquals(KeyboardCommand.DeleteBackward, undo.command)
    }

    @Test
    fun `undo is a no-op when composing is already empty`() {
        val undo = KeyboardReducer.undoLastCharacter(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            composeWords = true,
        )

        assertNull(undo.command)
        assertEquals("", undo.state.composing)
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
