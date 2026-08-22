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
    data class DeleteSurrounding(val before: Int, val after: Int) : KeyboardCommand
    data object PerformEditorAction : KeyboardCommand
    data class MoveCursor(val positions: Int) : KeyboardCommand
    data object DoubleSpacePeriod : KeyboardCommand
    data object FinishComposing : KeyboardCommand
    data object CycleSelectionCase : KeyboardCommand
}

/** Hold-delete starts on characters, then words, then the rest of the line. */
internal object DeleteHold {
    const val REPEAT_DELAY_MS = 380L
    const val CHAR_INTERVAL_MS = 55L
    const val WORD_AFTER_MS = 1_000L
    const val LINE_AFTER_MS = 2_200L
    const val WORD_INTERVAL_MS = 130L
    const val LINE_INTERVAL_MS = 200L

    enum class Stage { CHAR, WORD, LINE }

    fun stage(heldMs: Long): Stage = when {
        heldMs < WORD_AFTER_MS -> Stage.CHAR
        heldMs < LINE_AFTER_MS -> Stage.WORD
        else -> Stage.LINE
    }

    fun interval(heldMs: Long): Long = when (stage(heldMs)) {
        Stage.CHAR -> CHAR_INTERVAL_MS
        Stage.WORD -> WORD_INTERVAL_MS
        Stage.LINE -> LINE_INTERVAL_MS
    }

    fun command(
        heldMs: Long,
        swipeUndo: Boolean,
        before: CharSequence,
        after: CharSequence,
    ): KeyboardCommand {
        if (swipeUndo) {
            val span = SuggestionEngine.replaceableWord(before, after)
            return if (span != null) {
                KeyboardCommand.DeleteSurrounding(span.beforeLength, span.afterLength)
            } else {
                KeyboardCommand.DeleteBackward
            }
        }
        return when (stage(heldMs)) {
            Stage.CHAR -> KeyboardCommand.DeleteBackward
            Stage.WORD -> {
                val count = SuggestionEngine.wordBefore(before)
                if (count > 0) KeyboardCommand.DeleteSurrounding(count, 0)
                else KeyboardCommand.DeleteBackward
            }
            Stage.LINE -> {
                val count = SuggestionEngine.lineBefore(before)
                if (count > 0) KeyboardCommand.DeleteSurrounding(count, 0)
                else KeyboardCommand.DeleteBackward
            }
        }
    }
}

internal data class KeyboardReduction(
    val state: KeyboardState,
    val command: KeyboardCommand? = null,
)

internal data class ClipboardChip(
    val preview: String,
    val fullText: String,
    val imagePath: String? = null,
)

internal data class SuggestionItem(
    val text: String,
    val isEmoji: Boolean = false,
    /** Tapping this chip saves [text] to the personal dictionary. */
    val savesWord: Boolean = false,
)

/** What the single Gboard-style toolbar row should show. */
internal object KeyboardChrome {
    fun startedTyping(composing: String, textBeforeCursor: CharSequence): Boolean =
        composing.isNotEmpty() || textBeforeCursor.any { !it.isWhitespace() }

    /**
     * The clip chip and the suggestion strip share one row, so only one of them
     * can be on screen. The chip is an offer made while the field is idle; the
     * moment the user types, the row belongs to what they are producing.
     *
     * [startedTyping] is what makes that true. Without it the chip outlived the
     * empty field and sat where the word suggestions should be for the whole
     * sentence, because the render order in `DictationBar` reaches the clipboard
     * branch first and never falls through to the suggestions one.
     *
     * Deliberately hidden for the rest of the sentence rather than reappearing
     * whenever suggestions happen to run dry: a paste target that pops back
     * under a finger already moving toward a word would paste the entire
     * clipboard into the middle of what they were writing. Clearing the field
     * brings it back, which is the same condition that first offered it.
     */
    fun clipboardForStrip(
        clipboard: ClipboardChip?,
        startedTyping: Boolean,
        alreadyPasted: Boolean = false,
    ): ClipboardChip? = clipboard.takeIf { !alreadyPasted && !startedTyping }

    /**
     * Dismissing the chip hides that clip until a different one is copied.
     * Switching apps re-reads the same primary clip; that must not bring it back.
     */
    fun offersClipboardChip(
        clipText: String?,
        ignoredText: String?,
        chipEnabled: Boolean,
    ): Boolean = chipEnabled && !clipText.isNullOrEmpty() && clipText != ignoredText

    /** Short label on the chip. JSON is named instead of dumping the first keys. */
    fun clipboardPreview(text: String): String {
        val compact = text.replace('\n', ' ').trim()
        if (compact.startsWith("{") || compact.startsWith("[")) return "Copied JSON"
        return compact.take(24)
    }

    fun suggestionsForStrip(
        suggestions: List<SuggestionItem>,
        startedTyping: Boolean,
    ): List<SuggestionItem> = if (startedTyping) suggestions else emptyList()

    fun suggestionReplacesWord(
        composing: String,
        swipeChoicesActive: Boolean,
        stripReplacesWord: Boolean,
    ): Boolean = composing.isEmpty() && (swipeChoicesActive || stripReplacesWord)

    /** True only while the cursor is still sitting after the swiped word and its space. */
    fun swipeWordArmed(word: String?, before: CharSequence, after: CharSequence): Boolean {
        if (word.isNullOrEmpty()) return false
        val span = SuggestionEngine.replaceableWord(before, after) ?: return false
        return span.afterLength == 0 &&
            span.beforeLength > span.word.length &&
            span.word.equals(word, ignoreCase = true)
    }

    /**
     * What the shift key becomes when the service re-reads the caps mode at the
     * cursor, after a commit or a tap somewhere else in the field.
     *
     * Caps lock is the user's and the editor never asks for it, so a locked
     * keyboard ignores the answer. Everything else takes it, which is how a tap
     * into the middle of a word turns off a pending capital.
     */
    fun shiftAfterCursorSync(current: ShiftState, atCursor: ShiftState): ShiftState =
        if (current == ShiftState.LOCKED) ShiftState.LOCKED else atCursor

    fun swipeAlternatives(
        committed: String,
        swipeMatches: List<String>,
        similar: List<String>,
        limit: Int = 3,
    ): List<String> {
        val skip = committed.lowercase()
        return (swipeMatches.drop(1) + similar)
            .filter { it.lowercase() != skip }
            .distinctBy { it.lowercase() }
            .take(limit)
    }
}

internal data class SuggestionStrip(
    val words: List<String>,
    val emojis: List<String> = emptyList(),
    val replacesWord: Boolean = false,
    val saveWord: String? = null,
) {
    val items: List<SuggestionItem>
        get() = buildList {
            saveWord?.let { add(SuggestionItem(it, savesWord = true)) }
            addAll(words.map { SuggestionItem(it) })
            addAll(emojis.map { SuggestionItem(it, isEmoji = true) })
        }
}

/**
 * Distinguishes a tap in the field from the selection updates [setComposingText]
 * sends after every letter. Those updates put the cursor on the composing end;
 * a tap puts it somewhere else, and the next letter has to start there.
 */
internal object EditorCursorSync {
    fun isUserMove(
        oldSelStart: Int,
        oldSelEnd: Int,
        newSelStart: Int,
        newSelEnd: Int,
        oldCandidatesStart: Int,
        oldCandidatesEnd: Int,
        newCandidatesStart: Int,
        newCandidatesEnd: Int,
    ): Boolean {
        val collapsed = newSelStart == newSelEnd
        if (collapsed && newCandidatesStart >= 0 && newSelStart == newCandidatesEnd) {
            return false
        }
        if (
            newCandidatesStart < 0 &&
            oldCandidatesStart >= 0 &&
            collapsed &&
            newSelStart >= oldCandidatesEnd &&
            newSelStart <= oldCandidatesEnd + 1
        ) {
            return false
        }
        return newSelStart != oldSelStart || newSelEnd != oldSelEnd
    }
}

/**
 * Whether the editor's selected text has to be asked for.
 *
 * `InputConnection.getSelectedText` is a blocking round trip into the app being
 * typed into, and it was issued once per keystroke. While someone is typing the
 * answer is always the empty string, because there is no selection to return —
 * so the cheapest correct thing is to notice that from the bounds the editor
 * already told us and never make the call.
 *
 * A negative bound means no editor has reported yet, which is the one case
 * worth paying for.
 */
internal object EditorSelectionSync {
    fun mustReadSelection(selStart: Int, selEnd: Int): Boolean =
        selStart < 0 || selEnd < 0 || selStart != selEnd
}

internal data class WordSpan(
    val word: String,
    val beforeLength: Int,
    val afterLength: Int,
)

internal data class EditorTextWindow(
    val before: String = "",
    val after: String = "",
    val selected: String = "",
    val hasSelection: Boolean = false,
)

/**
 * Shift on a selection: Title case → ALL CAPS → lower → the original spelling.
 *
 * [original] is how the span looked when the cycle started. Mixed spellings
 * (iPhone) are not one of the three derived forms, so they come back as the
 * fourth step instead of being lost.
 */
internal object CaseCycle {
    fun next(text: String, original: String = text): String {
        if (text.none { it.isLetter() }) return text
        val options = linkedSetOf(
            title(text),
            text.uppercase(Locale.ROOT),
            text.lowercase(Locale.ROOT),
        )
        if (original !in options) options.add(original)
        val list = options.toList()
        val index = list.indexOf(text)
        return list[(index + 1).mod(list.size)]
    }

    private fun title(text: String): String = mapWords(text) { index, word ->
        if (index == 0) capitalize(word) else word.lowercase(Locale.ROOT)
    }

    private fun capitalize(word: String): String {
        val letter = word.indexOfFirst { it.isLetter() }
        if (letter < 0) return word
        return word.substring(0, letter) +
            word[letter].uppercaseChar() +
            word.substring(letter + 1).lowercase(Locale.ROOT)
    }

    private fun mapWords(text: String, transform: (Int, String) -> String): String {
        val out = StringBuilder(text.length)
        var wordIndex = 0
        var i = 0
        while (i < text.length) {
            if (isWordChar(text[i])) {
                val start = i
                while (i < text.length && isWordChar(text[i])) i++
                out.append(transform(wordIndex++, text.substring(start, i)))
            } else {
                out.append(text[i])
                i++
            }
        }
        return out.toString()
    }

    private fun isWordChar(character: Char): Boolean =
        character.isLetterOrDigit() || character == '\''
}


/** Pure keyboard-state reducer so behavior stays testable outside the IME process. */
internal object KeyboardReducer {
    const val CAPS_LOCK_WINDOW_MILLIS = 350L

    fun press(
        state: KeyboardState,
        key: KeyboardKey,
        nowMillis: Long,
        composeWords: Boolean = false,
        hasSelection: Boolean = false,
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
            if (hasSelection) {
                KeyboardReduction(
                    state = state.copy(composing = "", lastShiftTapMillis = null),
                    command = KeyboardCommand.CycleSelectionCase,
                )
            } else {
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

    /**
     * Reverses the character committed on pointer down when the gesture turns
     * into a swipe, or when a long-press replaces it with an accent.
     *
     * Letters go out on down so the glyph is on screen inside the 8.3 ms
     * 120 Hz budget (keyboard hot-path benchmark on a 120 Hz phone). A swipe
     * that started on "l" after "he" must then drop only that "l", not the
     * whole composing word, or the user loses "he" as well.
     */
    fun undoLastCharacter(
        state: KeyboardState,
        composeWords: Boolean,
        restoreShift: ShiftState? = null,
    ): KeyboardReduction {
        if (composeWords) {
            if (state.composing.isEmpty()) return KeyboardReduction(state)
            val next = state.composing.dropLast(1)
            return KeyboardReduction(
                state = state.copy(
                    composing = next,
                    shift = if (next.isEmpty()) restoreShift ?: state.shift else state.shift,
                    lastWasSpace = false,
                    capitalizeAfterSpace = false,
                ),
                command = KeyboardCommand.SetComposingText(next),
            )
        }
        return KeyboardReduction(
            state = state.copy(
                composing = "",
                shift = restoreShift ?: state.shift,
                lastWasSpace = false,
                capitalizeAfterSpace = false,
            ),
            command = KeyboardCommand.DeleteBackward,
        )
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
