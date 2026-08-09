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
    KEYBOARD_SWITCH,
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
)

internal sealed interface KeyboardCommand {
    data class CommitText(val text: String) : KeyboardCommand
    data object DeleteBackward : KeyboardCommand
    data object PerformEditorAction : KeyboardCommand
    data object SwitchKeyboard : KeyboardCommand
    data class MoveCursor(val positions: Int) : KeyboardCommand
}

internal data class KeyboardReduction(
    val state: KeyboardState,
    val command: KeyboardCommand? = null,
)

/** Pure keyboard-state reducer so behavior stays testable outside the IME process. */
internal object KeyboardReducer {
    const val CAPS_LOCK_WINDOW_MILLIS = 350L

    fun press(
        state: KeyboardState,
        key: KeyboardKey,
        nowMillis: Long,
    ): KeyboardReduction = when (key.type) {
        KeyboardKeyType.CHARACTER -> {
            val shifted = state.layer == KeyboardLayer.LETTERS && state.shift != ShiftState.OFF
            val output = if (shifted) key.output.uppercase(Locale.ROOT) else key.output
            val nextShift = if (state.shift == ShiftState.ONCE) ShiftState.OFF else state.shift
            KeyboardReduction(
                state = state.copy(
                    shift = nextShift,
                    lastShiftTapMillis = null,
                    capitalizeAfterSpace = output in SENTENCE_TERMINATORS,
                ),
                command = KeyboardCommand.CommitText(output),
            )
        }

        KeyboardKeyType.SPACE -> KeyboardReduction(
            state = state.copy(
                shift = when {
                    state.shift == ShiftState.LOCKED -> ShiftState.LOCKED
                    state.capitalizeAfterSpace -> ShiftState.ONCE
                    else -> state.shift
                },
                lastShiftTapMillis = null,
                capitalizeAfterSpace = false,
            ),
            command = KeyboardCommand.CommitText(" "),
        )

        KeyboardKeyType.DELETE -> KeyboardReduction(
            state = state.copy(capitalizeAfterSpace = false),
            command = KeyboardCommand.DeleteBackward,
        )

        KeyboardKeyType.RETURN -> KeyboardReduction(
            state = state.copy(
                shift = if (state.shift == ShiftState.LOCKED) ShiftState.LOCKED else ShiftState.ONCE,
                lastShiftTapMillis = null,
                capitalizeAfterSpace = false,
            ),
            command = KeyboardCommand.PerformEditorAction,
        )

        KeyboardKeyType.KEYBOARD_SWITCH -> KeyboardReduction(
            state = state,
            command = KeyboardCommand.SwitchKeyboard,
        )

        KeyboardKeyType.LAYER_SWITCH -> KeyboardReduction(
            state = state.copy(
                layer = key.targetLayer ?: KeyboardLayer.LETTERS,
                shift = if (key.targetLayer == KeyboardLayer.LETTERS) state.shift else ShiftState.OFF,
                lastShiftTapMillis = null,
            ),
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

    private val SENTENCE_TERMINATORS = setOf(".", "!", "?")
}
