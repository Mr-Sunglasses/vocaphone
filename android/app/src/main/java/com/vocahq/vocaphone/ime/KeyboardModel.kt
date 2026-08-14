package com.vocahq.vocaphone.ime

import java.util.Locale

internal enum class KeyboardLayer {
    LETTERS,
    NUMBERS,
    SYMBOLS,
    EMOJI,
}

internal enum class ShiftState {
    OFF,
    ONCE,
    LOCKED,
}

internal enum class KeyboardKeyType {
    CHARACTER,
    SHIFT,
    DELETE,
    SPACE,
    RETURN,
    LAYER_SWITCH,
}

internal data class KeyboardKey(
    val id: String,
    val label: String,
    val output: String = label,
    val type: KeyboardKeyType = KeyboardKeyType.CHARACTER,
    val weight: Float = 1f,
    val targetLayer: KeyboardLayer? = null,
)

internal data class KeyboardRow(
    val keys: List<KeyboardKey>,
    val leadingSpace: Float = 0f,
    val trailingSpace: Float = 0f,
)

internal data class KeyboardState(
    val layer: KeyboardLayer,
    val shift: ShiftState,
    val lastShiftTapMillis: Long? = null,
    val capitalizeAfterSpace: Boolean = false,
    val lastWasSpace: Boolean = false,
    val composing: String = "",
)

internal sealed interface KeyboardCommand {
    data class CommitText(val text: String) : KeyboardCommand
    data class SetComposingText(val text: String) : KeyboardCommand
    data object DeleteBackward : KeyboardCommand
    data object PerformEditorAction : KeyboardCommand
    data class MoveCursor(val positions: Int) : KeyboardCommand
    data object DoubleSpacePeriod : KeyboardCommand
    data object FinishComposing : KeyboardCommand
}

internal data class KeyboardReduction(
    val state: KeyboardState,
    val command: KeyboardCommand? = null,
)

internal data class ClipboardChip(
    val preview: String,
    val fullText: String,
)

/** What the single Gboard-style toolbar row should show. */
internal object KeyboardChrome {
    fun startedTyping(composing: String, textBeforeCursor: CharSequence): Boolean =
        composing.isNotEmpty() || textBeforeCursor.any { !it.isWhitespace() }

    fun clipboardForStrip(
        clipboard: ClipboardChip?,
        alreadyPasted: Boolean = false,
    ): ClipboardChip? = clipboard.takeIf { !alreadyPasted }

    fun suggestionsForStrip(suggestions: List<String>, startedTyping: Boolean): List<String> =
        if (startedTyping) suggestions else emptyList()
}

/** Pure keyboard-state reducer so behavior stays testable outside the IME process. */
internal object KeyboardReducer {
    const val CAPS_LOCK_WINDOW_MILLIS = 350L

    fun press(
        state: KeyboardState,
        key: KeyboardKey,
        nowMillis: Long,
        composeWords: Boolean = false,
    ): KeyboardReduction = when (key.type) {
        KeyboardKeyType.CHARACTER -> characterPress(state, key, composeWords)

        KeyboardKeyType.SPACE -> spacePress(state)

        KeyboardKeyType.DELETE -> {
            if (composeWords && state.composing.isNotEmpty()) {
                val next = state.composing.dropLast(1)
                KeyboardReduction(
                    state = state.copy(composing = next, capitalizeAfterSpace = false, lastWasSpace = false),
                    command = KeyboardCommand.SetComposingText(next),
                )
            } else {
                KeyboardReduction(
                    state = state.copy(composing = "", capitalizeAfterSpace = false, lastWasSpace = false),
                    command = KeyboardCommand.DeleteBackward,
                )
            }
        }

        KeyboardKeyType.RETURN -> KeyboardReduction(
            state = state.copy(
                shift = if (state.shift == ShiftState.LOCKED) ShiftState.LOCKED else ShiftState.ONCE,
                lastShiftTapMillis = null,
                capitalizeAfterSpace = false,
                lastWasSpace = false,
                composing = "",
            ),
            command = KeyboardCommand.PerformEditorAction,
        )

        KeyboardKeyType.LAYER_SWITCH -> KeyboardReduction(
            state = state.copy(
                layer = key.targetLayer ?: KeyboardLayer.LETTERS,
                shift = if (key.targetLayer == KeyboardLayer.LETTERS) state.shift else ShiftState.OFF,
                lastShiftTapMillis = null,
                lastWasSpace = false,
                composing = "",
            ),
            command = if (state.composing.isNotEmpty()) KeyboardCommand.FinishComposing else null,
        )

        KeyboardKeyType.SHIFT -> {
            val isDoubleTap = state.shift == ShiftState.ONCE &&
                state.lastShiftTapMillis?.let { nowMillis - it in 0..CAPS_LOCK_WINDOW_MILLIS } == true
            val nextShift = when {
                isDoubleTap -> ShiftState.LOCKED
                state.shift == ShiftState.OFF -> ShiftState.ONCE
                else -> ShiftState.OFF
            }
            KeyboardReduction(
                state = state.copy(
                    shift = nextShift,
                    lastShiftTapMillis = if (nextShift == ShiftState.ONCE) nowMillis else null,
                ),
            )
        }
    }

    private fun characterPress(
        state: KeyboardState,
        key: KeyboardKey,
        composeWords: Boolean,
    ): KeyboardReduction {
        val shifted = state.layer == KeyboardLayer.LETTERS && state.shift != ShiftState.OFF
        val output = if (shifted) key.output.uppercase(Locale.ROOT) else key.output
        val nextShift = if (state.shift == ShiftState.ONCE) ShiftState.OFF else state.shift
        val letter = composeWords &&
            state.layer == KeyboardLayer.LETTERS &&
            output.length == 1 &&
            output[0].isLetter()
        return if (letter) {
            val composing = state.composing + output
            KeyboardReduction(
                state = state.copy(
                    shift = nextShift,
                    lastShiftTapMillis = null,
                    capitalizeAfterSpace = false,
                    lastWasSpace = false,
                    composing = composing,
                ),
                command = KeyboardCommand.SetComposingText(composing),
            )
        } else {
            KeyboardReduction(
                state = state.copy(
                    shift = nextShift,
                    lastShiftTapMillis = null,
                    capitalizeAfterSpace = output in SENTENCE_TERMINATORS,
                    lastWasSpace = false,
                    composing = "",
                ),
                command = KeyboardCommand.CommitText(output),
            )
        }
    }

    private fun spacePress(state: KeyboardState): KeyboardReduction {
        if (state.lastWasSpace) {
            val nextShift = if (state.shift == ShiftState.LOCKED) ShiftState.LOCKED else ShiftState.ONCE
            return KeyboardReduction(
                state = state.copy(
                    shift = nextShift,
                    lastShiftTapMillis = null,
                    capitalizeAfterSpace = false,
                    lastWasSpace = false,
                    composing = "",
                ),
                command = KeyboardCommand.DoubleSpacePeriod,
            )
        }
        return KeyboardReduction(
            state = state.copy(
                shift = when {
                    state.shift == ShiftState.LOCKED -> ShiftState.LOCKED
                    state.capitalizeAfterSpace -> ShiftState.ONCE
                    else -> state.shift
                },
                lastShiftTapMillis = null,
                capitalizeAfterSpace = false,
                lastWasSpace = true,
                composing = "",
            ),
            command = KeyboardCommand.CommitText(" "),
        )
    }

    private val SENTENCE_TERMINATORS = setOf(".", "!", "?")
}
