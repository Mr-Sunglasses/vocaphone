package com.vocahq.vocaphone.ime

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.Locale

/**
 * A correction a word boundary just made: delete right after it puts [typed]
 * back, and the strip offers [typed] and [alternatives] until the next key.
 */
internal data class AutocorrectUndo(
    val typed: String,
    val fixed: String,
    /** What ended the word: a space, or one of `.,!?;:`. */
    val boundary: String,
    val alternatives: List<String> = emptyList(),
) {
    /** Delete: the boundary goes with the fix, and the typed word comes back with the cursor after it. */
    fun deleteCommand(): KeyboardCommand = KeyboardCommand.ReplaceBeforeCursor(fixed.length + boundary.length, typed)

    /** A chip tapped instead: [word] in place of the fix, the boundary kept. */
    fun replaceCommand(word: String): KeyboardCommand =
        KeyboardCommand.ReplaceBeforeCursor(fixed.length + boundary.length, word + boundary)

    /** What the strip shows while the correction can still be taken back. */
    val strip: List<SuggestionItem>
        get() = buildList {
            add(SuggestionItem(typed, kind = SuggestionKind.REVERT))
            alternatives
                .filter { !it.equals(fixed, ignoreCase = true) && !it.equals(typed, ignoreCase = true) }
                .distinctBy { it.lowercase(Locale.ROOT) }
                .take(2)
                .forEach { add(SuggestionItem(it, kind = SuggestionKind.REPLACE_FIX)) }
        }
}

/**
 * What the keyboard remembers about its own corrections in one field, beside
 * the reducer: the correction a delete would take back, the words the user put
 * back (never corrected again here), and a correction held across a layer
 * switch so `?` from the symbols still makes it.
 *
 * The decisions are made elsewhere ([Autocorrect], off the composition thread,
 * and [LearnedFixes]); this only applies them at the boundary key.
 */
internal class TypingCorrector {
    /** The correction delete would take back; drawn as the strip while set. */
    var undo by mutableStateOf<AutocorrectUndo?>(null)

    /** Bumped when [asserted] changes, so the strip is worked out again. */
    var assertedVersion by mutableIntStateOf(0)
        private set

    private val assertedWords = HashSet<String>()

    /** A word finished by a layer switch, and the fix its boundary should make. */
    private var held: Pair<String, String>? = null

    val asserted: Set<String> get() = assertedWords.toSet()

    /** A new field: nothing carries over. */
    fun reset() {
        undo = null
        held = null
        if (assertedWords.isNotEmpty()) {
            assertedWords.clear()
            assertedVersion++
        }
    }

    /** The cursor moved or the text changed under the keyboard. */
    fun forget() {
        undo = null
        held = null
    }

    /** [word] stays as typed in this field from now on. */
    fun assert(word: String) {
        if (assertedWords.add(word.lowercase(Locale.ROOT))) assertedVersion++
    }

    /** A layer switch finished [typed] while [fix] was pending for it. */
    fun hold(typed: String, fix: String?) {
        held = if (typed.isNotEmpty() && fix != null && fix != typed) typed to fix else null
    }

    /**
     * A boundary key after a layer switch: the edit that puts the held fix in
     * place of the word the switch finished, or null. Taken once.
     */
    fun takeHeld(boundary: String?): Pair<String, String>? {
        val pending = held
        held = null
        if (boundary == null || boundary == " " || isApostrophe(boundary) || pending == null) return null
        return pending
    }

    companion object {
        /** The characters that end a word and may correct it. */
        const val PUNCTUATION = ".,!?;:"

        /** `'` or `’`: inside a word ("don't"), so never where a correction lands. */
        fun isApostrophe(boundary: String): Boolean = boundary == "'" || boundary == "’"

        /** What [key] ends a word with, or null for a key that does not end one. */
        fun boundary(key: KeyboardKey): String? = when (key.type) {
            KeyboardKeyType.SPACE -> " "
            KeyboardKeyType.CHARACTER -> key.output.takeIf {
                it.length == 1 && (it[0] in PUNCTUATION || it[0] == '\'' || it[0] == '’')
            }
            else -> null
        }

        /**
         * What [typed] becomes when [boundary] ends it, or null to leave it.
         *
         * Nothing when corrections are off or the field takes none
         * ([autocorrect]: an address, a link, a password), when the user put
         * this word back in this field ([asserted]), or for an abbreviation
         * before its period. Then a learned fix ([learned]): it is the user's
         * own correction. Then the strip's decision, only if it was worked out
         * for this very word — space can arrive before the strip has caught up
         * with the last letter, and a fix meant for the word as it was a
         * keystroke ago must not land on the word as it is now. The short-word
         * table needs no scan, so it is applied even then.
         */
        fun correction(
            typed: String,
            boundary: String,
            learned: String?,
            strip: SuggestionStrip,
            autocorrect: Boolean,
            asserted: Set<String>,
            /** The personal dictionary has [typed]: the user's own spelling. */
            isPersonal: Boolean = false,
            /** What sits between the last whitespace and [typed]; see [Autocorrect.startsWord]. */
            tokenBefore: String = "",
        ): String? {
            if (typed.isEmpty()) return null
            if (isApostrophe(boundary)) {
                // "i'" can only be I'm, I'll, I've or I'd.
                return ShortWordCorrections.beforeApostrophe(typed).takeIf { autocorrect }
            }
            if (!autocorrect || typed.lowercase(Locale.ROOT) in asserted) return null
            // "Mr." and "etc." are typed on purpose.
            if (boundary == "." && SentenceBoundary.isAbbreviation(typed)) return null
            // The strip refuses these too; this covers space arriving before
            // it has caught up, when only the short-word table answers.
            if (isPersonal || !Autocorrect.startsWord(tokenBefore)) return null
            learned?.takeIf { it != typed }?.let { return it }
            // The strip has decided for this word, correction or none.
            if (strip.forWord == typed) return strip.autocorrection?.takeIf { it != typed }
            return ShortWordCorrections.replacement(typed)
                ?.takeIf { it != typed && (typed.length == 1 || !Autocorrect.isAllCaps(typed)) }
        }
    }
}

/** What tapping one of the strip's non-word chips does to the editor; see [SuggestionKind]. */
internal object TypingAssist {
    /**
     * The edits for [item], or null when it is a word to type the ordinary
     * way. [undo] is the correction still on offer; [after] the text after
     * the cursor, for the space an expanded snippet carries.
     */
    fun pick(item: SuggestionItem, undo: AutocorrectUndo?, after: String): List<KeyboardCommand>? = when (item.kind) {
        SuggestionKind.REVERT -> undo?.let { listOf(it.replaceCommand(it.typed)) }
        SuggestionKind.REPLACE_FIX -> undo?.let { listOf(it.replaceCommand(item.text)) }
        SuggestionKind.SNIPPET -> listOf(
            KeyboardCommand.ReplaceBeforeCursor(item.replaces.length, SuggestionEngine.suggestionCommit(item.text, after)),
        )
        SuggestionKind.RESULT -> listOf(KeyboardCommand.CommitText(item.text))
        else -> null
    }
}

/** What a strip chip reads as on screen. */
internal fun suggestionLabel(item: SuggestionItem): String = when {
    item.savesWord -> "+ ${item.text}"
    item.kind == SuggestionKind.KEEP_TYPED || item.kind == SuggestionKind.REVERT -> "“${item.text}”"
    item.kind == SuggestionKind.SNIPPET -> item.text.replace('\n', ' ')
    item.kind == SuggestionKind.RESULT -> "= ${item.text}"
    else -> item.text
}

/** What TalkBack says for a strip chip. */
internal fun suggestionDescription(item: SuggestionItem): String = when {
    item.savesWord -> "Add ${item.text} to dictionary"
    item.kind == SuggestionKind.AUTOCORRECT -> "${item.text}, correction"
    item.kind == SuggestionKind.KEEP_TYPED -> "Keep ${item.text}"
    item.kind == SuggestionKind.REVERT -> "Restore ${item.text}"
    item.kind == SuggestionKind.SNIPPET -> "Expand ${item.replaces} to ${item.text}"
    item.kind == SuggestionKind.RESULT -> "Insert result ${item.text}"
    else -> item.text
}
