package com.vocahq.vocaphone.ime

import java.util.Locale
import kotlin.math.floor

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
    /**
     * Drop the character that went out on pointer down and insert [text]
     * in the same batch. [DeleteBackward] is a key event, so a following
     * [CommitText] can land first and leave `2@` from a hold on `2`.
     */
    data class ReplaceLastCommitted(val text: String) : KeyboardCommand
    data object PerformEditorAction : KeyboardCommand
    data class MoveCursor(val positions: Int) : KeyboardCommand
    data object DoubleSpacePeriod : KeyboardCommand
    data object FinishComposing : KeyboardCommand
    data object CycleSelectionCase : KeyboardCommand
    /**
     * Shift was pressed while Compose did not think there was a selection.
     * The service still checks the live editor range: a stale `editorText`
     * snapshot used to arm caps instead of cycling case.
     */
    data object ShiftTap : KeyboardCommand
}

/**
 * Long-press accent row: hold still this long, then slide to pick a variant.
 *
 * The row grows to the right of the key and is shifted so every cell stays
 * on the keyboard. Swipe typing uses the same hold time so a slide after
 * the popup is up does not become a swipe.
 */
internal object AccentPicker {
    const val HOLD_MS = 380L
    const val CELL_DP = 36

    fun rowLeft(centerX: Float, count: Int, cellPx: Float, parentWidth: Float): Float {
        val width = count * cellPx
        if (count <= 0 || cellPx <= 0f) return 0f
        if (width >= parentWidth) return 0f
        val preferred = centerX - cellPx / 2f
        return preferred.coerceIn(0f, parentWidth - width)
    }

    fun indexAt(x: Float, rowLeft: Float, cellPx: Float, count: Int): Int {
        if (count <= 0 || cellPx <= 0f) return 0
        return floor((x - rowLeft) / cellPx).toInt().coerceIn(0, count - 1)
    }
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

    /** Apply [command] to the local before-cursor buffer used during a hold. */
    fun remainingBefore(before: String, command: KeyboardCommand): String = when (command) {
        KeyboardCommand.DeleteBackward -> before.dropLast(1)
        is KeyboardCommand.DeleteSurrounding -> before.dropLast(command.before)
        else -> before
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

    /**
     * What has to reach the editor before a swiped word is committed.
     *
     * A word typed but never spaced is still a composing region when the swipe
     * resolves. Clearing that region (`setComposingText("")`) deleted the word
     * from the editor, so the swiped word landed where it had been and read as
     * a replacement. Commit the pending word instead and add the space the user
     * never typed, so the swipe follows it.
     */
    fun swipePrefixCommand(composing: String): KeyboardCommand? =
        if (composing.isEmpty()) null else KeyboardCommand.CommitText(" ")

    /**
     * True while the cursor is still sitting on the swiped word. Some hosts
     * (Chrome omnibox, some web editors) drop the trailing space we send;
     * the strip still has to show the other same-path words so the user
     * can tap a neighbour of the path.
     */
    fun swipeWordArmed(word: String?, before: CharSequence, after: CharSequence): Boolean {
        if (word.isNullOrEmpty()) return false
        val span = SuggestionEngine.replaceableWord(before, after) ?: return false
        return span.afterLength == 0 &&
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

/**
 * How to apply a case cycle to a live selection.
 *
 * [restoreSelectionAfterFinish] is true when a composing span is still
 * active. `finishComposingText` on several editors (Messages among them)
 * drops the highlight, so the range has to be put back before `commitText`
 * can replace it. Capturing the selected string *before* that finish is
 * what keeps shift-to-cycle working after letters started going out as
 * composing text.
 */
internal data class CaseCycleApply(
    val next: String,
    val start: Int,
    val end: Int,
    val restoreSelectionAfterFinish: Boolean,
)

internal fun planCaseCycle(
    selected: String,
    original: String?,
    start: Int,
    composingActive: Boolean,
): CaseCycleApply? {
    if (selected.none { it.isLetter() }) return null
    val next = CaseCycle.next(selected, original ?: selected)
    return CaseCycleApply(
        next = next,
        start = start,
        end = start + next.length,
        restoreSelectionAfterFinish = composingActive,
    )
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
                    command = KeyboardCommand.ShiftTap,
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
     * into a swipe, or when a long-press replaces it with an accent or symbol.
     *
     * Letters go out on down so the glyph is on screen inside the 8.3 ms
     * 120 Hz budget (keyboard hot-path benchmark on a 120 Hz phone). A swipe
     * that started on "l" after "he" must then drop only that "l", not the
     * whole composing word, or the user loses "he" as well.
     *
     * Digits and punctuation skip composing ([characterPress] uses
     * [KeyboardCommand.CommitText]), so a hold on `2` for `@` has to delete
     * that committed `2` instead of no-op'ing on empty composing.
     *
     * The delete is [KeyboardCommand.DeleteSurrounding], not
     * [KeyboardCommand.DeleteBackward]. Backward-delete is a `KEYCODE_DEL`
     * key event in the IME; the editor can apply it after the following
     * commit, so a hold on `2` typed `2@`.
     */
    fun undoLastCharacter(
        state: KeyboardState,
        composeWords: Boolean,
        restoreShift: ShiftState? = null,
    ): KeyboardReduction {
        if (composeWords && state.composing.isNotEmpty()) {
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
            command = KeyboardCommand.DeleteSurrounding(1, 0),
        )
    }

    /**
     * Long-press replacement after the seed character has already gone out
     * on pointer down.
     *
     * A composing letter is rewritten in place (`hel` + hold `l` for `ł`
     * becomes `heł`). A digit or a letter-key symbol (`a` for `@`) is
     * deleted and replaced in one batch so the editor cannot keep both.
     */
    fun replaceLastCharacter(
        state: KeyboardState,
        replacement: String,
        composeWords: Boolean,
        restoreShift: ShiftState? = null,
    ): KeyboardReduction {
        val undone = undoLastCharacter(state, composeWords, restoreShift)
        val typed = characterPress(
            undone.state,
            KeyboardKey(
                id = "variant-$replacement",
                label = replacement,
                output = replacement,
            ),
            composeWords,
        )
        // Accents stay in the composing region (`e` → `é`). A symbol is
        // CommitText, and finishing composing first would keep the letter
        // (`a` then `@`). Batch-delete the seed and insert the symbol.
        val command = when (val typedCommand = typed.command) {
            is KeyboardCommand.SetComposingText -> typedCommand
            is KeyboardCommand.CommitText ->
                KeyboardCommand.ReplaceLastCommitted(typedCommand.text)
            else -> typedCommand
        }
        return KeyboardReduction(state = typed.state, command = command)
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
