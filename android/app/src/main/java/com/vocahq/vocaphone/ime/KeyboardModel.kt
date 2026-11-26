package com.vocahq.vocaphone.ime

import java.util.Locale
import kotlin.math.floor

internal enum class KeyboardLayer {
    LETTERS,
    NUMBERS,
    SYMBOLS,
    EMOJI,
    /** Dial pad for phone-number fields. */
    PHONE,
    /** Number pad for number and date/time fields. */
    NUMPAD,
}

/** Which number pad a numeric field gets; see [KeyboardLayouts.padRows]. */
internal enum class PadKind {
    NUMBER,
    DATETIME,
    PHONE,
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
    /** Next typing layout ([KeyboardLanguages]). Handled by the keyboard, not the reducer. */
    LANGUAGE,
}

internal data class KeyboardKey(
    val id: String,
    val label: String,
    val output: String = label,
    val type: KeyboardKeyType = KeyboardKeyType.CHARACTER,
    val weight: Float = 1f,
    val targetLayer: KeyboardLayer? = null,
    /**
     * What a hold offers instead of [KeyAccents]' table, or null for the
     * table. Empty means nothing: a dial pad's 2 should not offer `@`.
     */
    val popup: List<String>? = null,
    /** Small second line under the label, like ABC on a dial pad's 2. */
    val caption: String? = null,
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
    /**
     * What has been typed since the last space or return, the composing word
     * included ("e.g" before its second period). Empty when unknown, after the
     * cursor moved. Bounded; only its end is ever read.
     */
    val token: String = "",
    /**
     * [token] began at the start of a line: after return, or in a field the
     * keyboard has just come up in. A number there followed by a period is a
     * list item ("3. "), not the end of a sentence. False once unknown.
     */
    val lineStart: Boolean = true,
    /** The last space followed a word (a letter or digit), so a second one may close the sentence. */
    val spaceAfterWord: Boolean = false,
    /** When that space went out, for the double-space window. */
    val lastSpaceMillis: Long? = null,
) {
    /**
     * A word and its space went out together: a picked suggestion, a swipe.
     * A second space right after it closes the sentence, as after a typed word.
     */
    fun afterWordAndSpace(nowMillis: Long): KeyboardState = copy(
        composing = "",
        lastWasSpace = true,
        capitalizeAfterSpace = false,
        token = "",
        lineStart = false,
        spaceAfterWord = true,
        lastSpaceMillis = nowMillis,
    )
}

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
    /**
     * Delete [length] characters before the cursor and type [text] in one
     * batch: a learned fix taken back ("the " back to "teh").
     */
    data class ReplaceBeforeCursor(val length: Int, val text: String) : KeyboardCommand
    data object PerformEditorAction : KeyboardCommand
    /** [positions] characters right (negative: left) and [lines] lines down (negative: up). */
    data class MoveCursor(val positions: Int, val lines: Int = 0) : KeyboardCommand
    data object DoubleSpacePeriod : KeyboardCommand
    data object FinishComposing : KeyboardCommand
    data object CycleSelectionCase : KeyboardCommand
    /**
     * Shift was pressed while Compose did not think there was a selection.
     * The service still checks the live editor range: a stale `editorText`
     * snapshot used to arm caps instead of cycling case.
     */
    data object ShiftTap : KeyboardCommand
    /** A text-editing panel button; [selecting] when its Select is on. See [TextEditing]. */
    data class EditText(val action: TextEditAction, val selecting: Boolean = false) : KeyboardCommand
}

/**
 * Long-press accent row: hold still this long, then slide to pick a variant.
 *
 * The row grows to the right of the key and is shifted so every cell stays
 * on the keyboard. Swipe typing uses the same hold time so a slide after
 * the popup is up does not become a swipe.
 */
internal object AccentPicker {
    /**
     * AOSP LatinIME's `config_default_longpress_key_timeout` and Gboard's
     * default "Key long press delay": 300 ms. Was 380 ms with no recorded reason.
     */
    const val HOLD_MS = 300L
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
    /** LatinIME `config_key_repeat_start_timeout` (400 ms) and `config_key_repeat_interval` (50 ms). */
    const val REPEAT_DELAY_MS = 400L
    const val CHAR_INTERVAL_MS = 50L
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

/**
 * Delete slid left: each key width the finger travels left of where it went
 * down deletes one more word, Option-Delete style (the spaces and punctuation
 * before the cursor go with the word before them). Sliding back right types
 * those words back, newest first; lifting keeps what is deleted.
 *
 * Works on [before], the text before the cursor the delete hold already
 * keeps, so a step never waits for an editor read.
 */
internal class DeleteSlide(before: String) {
    private val buffer = StringBuilder(before)
    private val deleted = ArrayList<String>()

    val steps: Int get() = deleted.size

    /** What is left before the cursor. */
    val before: String get() = buffer.toString()

    /** The edits that take the slide to [target] words deleted. */
    fun moveTo(target: Int): List<KeyboardCommand> {
        val wanted = target.coerceAtLeast(0)
        val commands = ArrayList<KeyboardCommand>()
        while (deleted.size < wanted) {
            val count = SuggestionEngine.wordWithSeparatorsBefore(buffer)
            if (count <= 0) break
            val start = buffer.length - count
            deleted.add(buffer.substring(start))
            buffer.setLength(start)
            commands.add(KeyboardCommand.DeleteSurrounding(count, 0))
        }
        while (deleted.size > wanted) {
            val word = deleted.removeAt(deleted.lastIndex)
            buffer.append(word)
            commands.add(KeyboardCommand.CommitText(word))
        }
        return commands
    }

    companion object {
        /** Words deleted for a finger [travelPx] left of where it went down, on keys [keyWidthPx] wide. */
        fun stepsFor(travelPx: Float, keyWidthPx: Float): Int =
            if (keyWidthPx <= 0f || travelPx <= 0f) 0 else (travelPx / keyWidthPx).toInt()
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
    val kind: SuggestionKind = SuggestionKind.WORD,
    /** What a [SuggestionKind.SNIPPET] chip replaces before the cursor: its trigger. */
    val replaces: String = "",
)

internal enum class SuggestionKind {
    WORD,
    /** The word space will put in place of the one being typed. Drawn bold. */
    AUTOCORRECT,
    /** The word being typed, as typed: tapping it keeps it, and it is not corrected again here. */
    KEEP_TYPED,
    /** Right after a correction: what was typed. Tapping it puts it back. */
    REVERT,
    /** Right after a correction: another word to put in place of the fix. */
    REPLACE_FIX,
    /** A snippet whose trigger was just typed; tapping it expands the trigger. */
    SNIPPET,
    /** The result of the sum before the cursor; tapping it types it. */
    RESULT,
    ;

    /** Chips that are a dictionary word on offer, and so can be blocked with a long press. */
    val blockable: Boolean get() = this == WORD || this == AUTOCORRECT || this == REPLACE_FIX
}

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
     * sentence.
     *
     * A swipe on an empty field is the other producer. `applySwipe` fills
     * alternatives and clears composing before the coalesced editor read, so
     * [startedTyping] can still be false while those choices are already on
     * the strip. [swipeChoicesActive] hides the chip for that window.
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
        swipeChoicesActive: Boolean = false,
        alreadyPasted: Boolean = false,
    ): ClipboardChip? =
        clipboard.takeIf { !alreadyPasted && !startedTyping && !swipeChoicesActive }

    /**
     * Swipe alternatives are filled in `applySwipe` before the coalesced
     * editor read. [swipeWordArmed] still needs that read, so an empty field
     * can have choices that are neither armed nor "typing" yet.
     */
    fun swipeChoicesActive(
        hasChoices: Boolean,
        swipeArmed: Boolean,
        startedTyping: Boolean,
        composing: String,
    ): Boolean = hasChoices && (swipeArmed || (!startedTyping && composing.isEmpty()))

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

    /**
     * What the shift key becomes when "Capitalize sentences" turns off under
     * an open editor. That includes the first settings load: DataStore can
     * answer after `onStartInput` has already armed shift from the default.
     *
     * Only a shift the keyboard armed by itself is dropped. If the user has
     * pressed shift since, [current] no longer matches [autoArmed] and stays.
     */
    fun shiftWhenAutoCapitalizeOff(current: ShiftState, autoArmed: ShiftState): ShiftState =
        if (current == autoArmed) ShiftState.OFF else current

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
    /** What space or `.,!?;:` will put in place of [forWord]; see [Autocorrect]. */
    val autocorrection: String? = null,
    /** The composing word this strip was worked out for. Space applies [autocorrection] only to that word. */
    val forWord: String? = null,
    /** The typed word, offered as typed beside a pending [autocorrection]. */
    val keepTyped: String? = null,
    /** Snippet and sum chips ([TypingChips]), ahead of everything else. */
    val extras: List<SuggestionItem> = emptyList(),
) {
    val items: List<SuggestionItem>
        get() = buildList {
            addAll(extras)
            saveWord?.let { add(SuggestionItem(it, savesWord = true)) }
            keepTyped?.let { add(SuggestionItem(it, kind = SuggestionKind.KEEP_TYPED)) }
            addAll(
                words.map {
                    SuggestionItem(it, kind = if (it == autocorrection) SuggestionKind.AUTOCORRECT else SuggestionKind.WORD)
                },
            )
            addAll(emojis.map { SuggestionItem(it, isEmoji = true) })
        }

    /** The autocorrection for [typed], if this strip was worked out for it. */
    fun autocorrectionFor(typed: String): String? =
        autocorrection?.takeIf { typed.isNotEmpty() && forWord == typed }

    /** This strip with [word] gone, for a chip just blocked. */
    fun without(word: String): SuggestionStrip {
        val key = word.lowercase(Locale.ROOT)
        val dropped = autocorrection?.lowercase(Locale.ROOT) == key
        return copy(
            words = words.filter { it.lowercase(Locale.ROOT) != key },
            autocorrection = autocorrection.takeUnless { dropped },
            keepTyped = keepTyped.takeUnless { dropped },
        )
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
 * Where the keyboard's own edits will leave the cursor, so the selection
 * updates they cause are not taken for a tap in the field.
 *
 * [EditorCursorSync] only recognises updates around a composing region. A
 * plain `commitText` — every letter on a layout that does not compose words,
 * a space or punctuation after one — moves the cursor with no composing region
 * on either side, so it looked like a tap: a `finishComposingText` and a
 * `getCursorCapsMode` round trip into the app per key, and the keyboard's own
 * state (the space a double space closes, the token "etc." is judged by, a
 * held correction) wiped each time.
 *
 * The keyboard knows what each of its edits does to the cursor, so it says so
 * here as it sends them, and an update landing exactly where one of them
 * lands is that edit's echo. Updates arrive in the order the edits went out;
 * an editor may coalesce several into one, which then matches the last, so
 * a match also drops every expectation before it. Anything that does not
 * match — a tap, an app rewriting its text, an edit the keyboard could not
 * predict — re-anchors the forecast on what the editor reported and is left
 * to [EditorCursorSync], exactly as before. A wrong forecast therefore
 * costs only what every key cost before it existed.
 *
 * No editor reads: a few integers per edit, on the main thread.
 */
internal class SelectionForecast {
    /** Where the cursor will be once every edit sent so far has landed; -1 when unknown. */
    var cursor: Int = -1
        private set

    /** Where the composing region those edits leave starts; -1 for none. */
    private var composingStart = -1

    private val pending = IntArray(CAPACITY)
    private var pendingCount = 0

    /** The editor reported [selStart]..[selEnd] (and a composing region from [candidatesStart]). */
    fun reset(selStart: Int, selEnd: Int, candidatesStart: Int = -1) {
        cursor = if (selStart >= 0 && selStart == selEnd) selStart else -1
        composingStart = if (cursor >= 0 && candidatesStart in 0..cursor) candidatesStart else -1
        pendingCount = 0
    }

    /** An edit whose result cannot be worked out here: wait for the editor to say. */
    fun forget() {
        cursor = -1
        composingStart = -1
    }

    /** `setComposingText(text, 1)` with [length] characters. */
    fun compose(length: Int) {
        if (cursor < 0) return
        val start = if (composingStart >= 0) composingStart else cursor
        cursor = start + length
        composingStart = if (length > 0) start else -1
        expect(cursor)
    }

    /**
     * Composing finished (when there was a region), [deleteBefore] characters
     * deleted before the cursor, then `commitText(text, 1)` with [length]
     * characters, all in one batch.
     */
    fun commit(length: Int, deleteBefore: Int = 0) {
        if (cursor < 0) return
        cursor = (cursor - deleteBefore).coerceAtLeast(0) + length
        composingStart = -1
        expect(cursor)
    }

    /** `finishComposingText` alone: the region goes, the cursor stays. */
    fun finishComposing() {
        if (cursor < 0 || composingStart < 0) return
        composingStart = -1
        expect(cursor)
    }

    /**
     * An `onUpdateSelection`: true when it is the echo of an edit the keyboard
     * forecast, false when the editor has to be believed instead.
     */
    fun onUpdate(selStart: Int, selEnd: Int, candidatesStart: Int): Boolean {
        if (selStart >= 0 && selStart == selEnd) {
            for (index in 0 until pendingCount) {
                if (pending[index] != selStart) continue
                val rest = pendingCount - index - 1
                pending.copyInto(pending, 0, index + 1, pendingCount)
                pendingCount = rest
                return true
            }
        }
        reset(selStart, selEnd, candidatesStart)
        return false
    }

    private fun expect(position: Int) {
        if (pendingCount == CAPACITY) {
            // Thirty-two edits with no word back from the editor: it is not
            // reporting, so stop guessing rather than match a stale position.
            forget()
            pendingCount = 0
            return
        }
        pending[pendingCount++] = position
    }

    private companion object {
        const val CAPACITY = 32
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
    /** LatinIME's double-tap-shift window is `ViewConfiguration.getDoubleTapTimeout()`, 300 ms. */
    const val CAPS_LOCK_WINDOW_MILLIS = 300L

    fun press(
        state: KeyboardState,
        key: KeyboardKey,
        nowMillis: Long,
        composeWords: Boolean = false,
        hasSelection: Boolean = false,
        autoCapitalize: Boolean = true,
        doubleSpacePeriod: Boolean = true,
    ): KeyboardReduction = when (key.type) {
        KeyboardKeyType.CHARACTER -> characterPress(state, key, composeWords, autoCapitalize)

        KeyboardKeyType.SPACE -> spacePress(state, autoCapitalize, nowMillis, doubleSpacePeriod)

        KeyboardKeyType.DELETE -> {
            val token = state.token.dropLast(1)
            // Deleting past the token's start reaches text the keyboard did not see typed.
            val lineStart = state.lineStart && state.token.isNotEmpty()
            if (composeWords && state.composing.isNotEmpty()) {
                val next = state.composing.dropLast(1)
                KeyboardReduction(
                    state = state.copy(composing = next, capitalizeAfterSpace = false, lastWasSpace = false, token = token, lineStart = lineStart),
                    command = KeyboardCommand.SetComposingText(next),
                )
            } else {
                KeyboardReduction(
                    state = state.copy(composing = "", capitalizeAfterSpace = false, lastWasSpace = false, token = token, lineStart = lineStart),
                    command = KeyboardCommand.DeleteBackward,
                )
            }
        }

        KeyboardKeyType.RETURN -> KeyboardReduction(
            state = state.copy(
                shift = when {
                    state.shift == ShiftState.LOCKED -> ShiftState.LOCKED
                    autoCapitalize -> ShiftState.ONCE
                    else -> ShiftState.OFF
                },
                lastShiftTapMillis = null,
                capitalizeAfterSpace = false,
                lastWasSpace = false,
                composing = "",
                token = "",
                lineStart = true,
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

        KeyboardKeyType.LANGUAGE -> KeyboardReduction(
            state = state.copy(composing = "", lastWasSpace = false, capitalizeAfterSpace = false),
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
        autoCapitalize: Boolean,
    ): KeyboardReduction {
        val shifted = state.layer == KeyboardLayer.LETTERS && state.shift != ShiftState.OFF
        val output = if (shifted) key.output.uppercase(Locale.ROOT) else key.output
        val nextShift = if (state.shift == ShiftState.ONCE) ShiftState.OFF else state.shift
        val letter = composeWords &&
            state.layer == KeyboardLayer.LETTERS &&
            output.length == 1 &&
            output[0].isLetter()
        val token = (state.token + output).takeLast(TOKEN_LIMIT)
        return if (letter) {
            val composing = state.composing + output
            KeyboardReduction(
                state = state.copy(
                    shift = nextShift,
                    lastShiftTapMillis = null,
                    capitalizeAfterSpace = false,
                    lastWasSpace = false,
                    composing = composing,
                    token = token,
                ),
                command = KeyboardCommand.SetComposingText(composing),
            )
        } else {
            // "e.g. ", "Mr. " and "3. " end in a period and not a sentence.
            val endsSentence = output in SENTENCE_TERMINATORS &&
                !(output == "." && SentenceBoundary.isAbbreviation(state.token, atLineStart = state.lineStart))
            KeyboardReduction(
                state = state.copy(
                    shift = nextShift,
                    lastShiftTapMillis = null,
                    capitalizeAfterSpace = autoCapitalize && endsSentence,
                    lastWasSpace = false,
                    composing = "",
                    token = token,
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
                    token = state.token.dropLast(1),
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
                token = state.token.dropLast(1),
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
        autoCapitalize: Boolean = true,
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
            autoCapitalize,
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

    /**
     * A second space closes the sentence, the way people type by reflex — but
     * only within [DOUBLE_SPACE_WINDOW_MILLIS] of the first, and only when the
     * first followed a word. After "Hello." it used to make "Hello.. ".
     */
    private fun spacePress(
        state: KeyboardState,
        autoCapitalize: Boolean,
        nowMillis: Long,
        doubleSpacePeriod: Boolean,
    ): KeyboardReduction {
        val inWindow = state.lastSpaceMillis?.let { nowMillis - it in 0..DOUBLE_SPACE_WINDOW_MILLIS } == true
        if (doubleSpacePeriod && state.lastWasSpace && state.spaceAfterWord && inWindow) {
            val nextShift = when {
                state.shift == ShiftState.LOCKED -> ShiftState.LOCKED
                autoCapitalize -> ShiftState.ONCE
                else -> state.shift
            }
            return KeyboardReduction(
                state = state.copy(
                    shift = nextShift,
                    lastShiftTapMillis = null,
                    capitalizeAfterSpace = false,
                    lastWasSpace = false,
                    composing = "",
                    token = "",
                    lineStart = false,
                    spaceAfterWord = false,
                    lastSpaceMillis = null,
                ),
                command = KeyboardCommand.DoubleSpacePeriod,
            )
        }
        val afterWord = state.composing.isNotEmpty() || state.token.lastOrNull()?.isLetterOrDigit() == true
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
                token = "",
                lineStart = false,
                spaceAfterWord = afterWord && !state.lastWasSpace,
                lastSpaceMillis = nowMillis,
            ),
            command = KeyboardCommand.CommitText(" "),
        )
    }

    /** The iOS keyboard's window for a double space, in milliseconds. */
    const val DOUBLE_SPACE_WINDOW_MILLIS = 1_200L

    private const val TOKEN_LIMIT = 24

    private val SENTENCE_TERMINATORS = setOf(".", "!", "?")
}
