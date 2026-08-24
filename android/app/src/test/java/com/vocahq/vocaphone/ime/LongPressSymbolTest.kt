package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Long-press of a number-row key, replayed the way the IME talks to the
 * editor.
 *
 * #196 made the reducer emit a delete before `@`, but that delete was
 * [KeyboardCommand.DeleteBackward], which the IME sends as `KEYCODE_DEL`.
 * Key events are applied by the target app after `commitText`, so a hold
 * on `2` still typed `2@`. The replacement has to be
 * [KeyboardCommand.ReplaceLastCommitted], which deletes and inserts in
 * one batch.
 */
class LongPressSymbolTest {

    @Test
    fun `holding 2 for at-sign leaves only the at-sign`() {
        val editor = FakeEditor()
        var state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)

        state = editor.type(state, "2")
        assertEquals("2", editor.text)

        editor.replace(state, "@")
        assertEquals("@", editor.text)
    }

    @Test
    fun `holding 2 after a letter keeps the letter`() {
        val editor = FakeEditor()
        var state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)

        state = editor.type(state, "h")
        state = editor.type(state, "2")
        assertEquals("h2", editor.text)

        editor.replace(state, "@")
        assertEquals("h@", editor.text)
    }

    @Test
    fun `holding a for at-sign leaves only the at-sign`() {
        val editor = FakeEditor()
        var state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)

        state = editor.type(state, "a")
        assertEquals("a", editor.text)

        editor.replace(state, "@")
        assertEquals("@", editor.text)
    }

    @Test
    fun `holding a for at-sign after a letter keeps that letter`() {
        val editor = FakeEditor()
        var state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)

        state = editor.type(state, "h")
        state = editor.type(state, "a")
        assertEquals("ha", editor.text)

        editor.replace(state, "@")
        assertEquals("h@", editor.text)
    }

    @Test
    fun `holding e for an accent rewrites the composing letter`() {
        val editor = FakeEditor()
        var state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)

        state = editor.type(state, "h")
        state = editor.type(state, "e")
        assertEquals("he", editor.text)

        editor.replace(state, "é")
        assertEquals("hé", editor.text)
    }

    @Test
    fun `a key-event undo after commitText leaves both characters`() {
        val editor = FakeEditor()
        editor.apply(KeyboardCommand.CommitText("2"))
        editor.apply(KeyboardCommand.DeleteBackward)
        editor.apply(KeyboardCommand.CommitText("@"))
        assertEquals("2@", editor.text)
    }

    /**
     * Mirrors `VocaPhoneInputMethodService.handleCommand` for the commands
     * this path uses. [KeyboardCommand.DeleteBackward] is a key event, so
     * it does not mutate the buffer before a following commit.
     */
    private class FakeEditor {
        private val buffer = StringBuilder()
        private var composingStart = -1

        val text: String get() = buffer.toString()

        fun apply(command: KeyboardCommand) {
            when (command) {
                is KeyboardCommand.SetComposingText -> {
                    if (composingStart < 0) composingStart = buffer.length
                    buffer.setLength(composingStart)
                    buffer.append(command.text)
                    if (command.text.isEmpty()) composingStart = -1
                }
                is KeyboardCommand.CommitText -> {
                    composingStart = -1
                    buffer.append(command.text)
                }
                is KeyboardCommand.ReplaceLastCommitted -> {
                    composingStart = -1
                    if (buffer.isNotEmpty()) buffer.deleteCharAt(buffer.length - 1)
                    buffer.append(command.text)
                }
                KeyboardCommand.DeleteBackward -> {
                    // sendKeyEvent(KEYCODE_DEL): the editor applies this later.
                }
                is KeyboardCommand.DeleteSurrounding -> {
                    composingStart = -1
                    val n = command.before.coerceAtMost(buffer.length)
                    if (n > 0) buffer.delete(buffer.length - n, buffer.length)
                }
                KeyboardCommand.FinishComposing -> composingStart = -1
                else -> throw IllegalArgumentException("unexpected $command")
            }
        }

        fun type(state: KeyboardState, digitOrLetter: String): KeyboardState {
            val reduction = KeyboardReducer.press(
                state = state,
                key = KeyboardKey(
                    id = "character-$digitOrLetter",
                    label = digitOrLetter,
                    output = digitOrLetter,
                ),
                nowMillis = 1_000,
                composeWords = true,
            )
            reduction.command?.let(::apply)
            return reduction.state
        }

        fun replace(state: KeyboardState, replacement: String): KeyboardState {
            val reduction = KeyboardReducer.replaceLastCharacter(
                state = state,
                replacement = replacement,
                composeWords = true,
            )
            reduction.command?.let(::apply)
            return reduction.state
        }
    }
}
