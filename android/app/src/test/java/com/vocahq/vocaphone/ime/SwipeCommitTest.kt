package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * What a swipe leaves in the editor, replayed end to end.
 *
 * A swipe is not one command: the seed letter goes out on pointer down, the
 * gesture takes it back, and the resolved word is committed a frame or more
 * later, on top of whatever composing region is still open. The bug that
 * motivated this file (#197) only showed up in that sequence — every step in it
 * was correct on its own — so the test keeps the sequence rather than the
 * steps.
 */
class SwipeCommitTest {

    @Test
    fun `a swipe after a word that was never spaced keeps that word`() {
        val editor = FakeEditor()
        var state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)

        state = editor.type(state, "h", "i")
        assertEquals("hi", editor.text)

        // The swipe starts on "w": the letter is committed on pointer down so
        // it is on screen inside the frame, then the gesture undoes it.
        state = editor.type(state, "w")
        state = editor.undoSeed(state)
        assertEquals("hi", editor.text)

        editor.swipe(state, "world")

        assertEquals("hi world ", editor.text)
    }

    @Test
    fun `a swipe after a spaced word reads the same as one after an unspaced word`() {
        val editor = FakeEditor()
        var state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)

        state = editor.type(state, "h", "i")
        state = editor.space(state)
        state = editor.type(state, "w")
        state = editor.undoSeed(state)
        assertEquals("hi ", editor.text)

        editor.swipe(state, "world")

        assertEquals("hi world ", editor.text)
    }

    @Test
    fun `a swipe into an empty field commits the word and its space`() {
        val editor = FakeEditor()
        var state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)

        state = editor.type(state, "w")
        state = editor.undoSeed(state)

        editor.swipe(state, "world")

        assertEquals("world ", editor.text)
    }

    @Test
    fun `two swipes in a row are two words`() {
        val editor = FakeEditor()
        var state = KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF)

        state = editor.type(state, "h")
        state = editor.undoSeed(state)
        state = editor.swipe(state, "hello")

        state = editor.type(state, "w")
        state = editor.undoSeed(state)
        editor.swipe(state, "world")

        assertEquals("hello world ", editor.text)
    }

    /**
     * The editor side of the `InputConnection` contract, held to the part the
     * keyboard uses: a composing region that `setComposingText` rewrites and
     * that any commit ends. `apply` mirrors `VocaPhoneInputMethodService.
     * handleCommand`, including its `finishComposingText` before a commit —
     * that is what makes a commit land *after* the composing word instead of
     * replacing it.
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
                KeyboardCommand.FinishComposing -> composingStart = -1
                else -> throw IllegalArgumentException("unexpected $command")
            }
        }

        fun type(state: KeyboardState, vararg letters: String): KeyboardState {
            var next = state
            letters.forEach { letter ->
                val reduction = KeyboardReducer.press(
                    state = next,
                    key = KeyboardKey(id = "character-$letter", label = letter, output = letter),
                    nowMillis = 1_000,
                    composeWords = true,
                )
                next = reduction.state
                reduction.command?.let(::apply)
            }
            return next
        }

        fun space(state: KeyboardState): KeyboardState {
            val reduction = KeyboardReducer.press(
                state = state,
                key = KeyboardKey(id = "space", label = "Space", type = KeyboardKeyType.SPACE),
                nowMillis = 1_000,
                composeWords = true,
            )
            reduction.command?.let(::apply)
            return reduction.state
        }

        fun undoSeed(state: KeyboardState): KeyboardState {
            val reduction = KeyboardReducer.undoLastCharacter(state, composeWords = true)
            reduction.command?.let(::apply)
            return reduction.state
        }

        /** `VocaPhoneKeyboard.applySwipe` plus the service's `commitSuggestion`. */
        fun swipe(state: KeyboardState, word: String): KeyboardState {
            KeyboardChrome.swipePrefixCommand(state.composing)?.let(::apply)
            composingStart = -1
            buffer.append(SuggestionEngine.suggestionCommit(word, textAfterCursor = ""))
            return state.copy(composing = "", lastWasSpace = true, capitalizeAfterSpace = false)
        }
    }
}
