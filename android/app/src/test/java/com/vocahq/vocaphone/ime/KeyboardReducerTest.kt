package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
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
    fun `double tapping shift enables caps lock`() {
        val first = KeyboardReducer.press(
            KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF),
            shiftKey(),
            nowMillis = 1_000,
        )
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
