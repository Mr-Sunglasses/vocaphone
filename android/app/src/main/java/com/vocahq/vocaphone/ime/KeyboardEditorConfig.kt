package com.vocahq.vocaphone.ime

import android.text.InputType
import android.view.inputmethod.EditorInfo
import com.vocahq.vocaphone.core.ImeInputPolicy

internal enum class ReturnKeyKind {
    ENTER,
    GO,
    NEXT,
    SEARCH,
    SEND,
    DONE,
    PREVIOUS,
}
internal data class KeyboardEditorConfig(
    val sessionId: Int,
    val initialLayer: KeyboardLayer,
    val initialShift: ShiftState,
    val returnKey: ReturnKeyKind,
    val editorActionId: Int?,
    val leadingPunctuation: String,
    val dictationAllowed: Boolean,
    val sensitive: Boolean,
    val shiftSync: Int = 0,
    val cursorSync: Int = 0,
) {
    companion object {
        fun empty() = KeyboardEditorConfig(
            sessionId = 0,
            initialLayer = KeyboardLayer.LETTERS,
            initialShift = ShiftState.OFF,
            returnKey = ReturnKeyKind.ENTER,
            editorActionId = null,
            leadingPunctuation = ",",
            dictationAllowed = false,
            sensitive = false,
        )

        fun shiftFromCapsMode(capsMode: Int): ShiftState = when {
            capsMode and InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS != 0 -> ShiftState.LOCKED
            capsMode != 0 -> ShiftState.ONCE
            else -> ShiftState.OFF
        }

        fun from(info: EditorInfo?, sessionId: Int): KeyboardEditorConfig {
            val inputType = info?.inputType ?: InputType.TYPE_NULL
            val inputClass = inputType and InputType.TYPE_MASK_CLASS
            val initialLayer = when (inputClass) {
                InputType.TYPE_CLASS_NUMBER,
                InputType.TYPE_CLASS_PHONE,
                InputType.TYPE_CLASS_DATETIME,
                -> KeyboardLayer.NUMBERS

                else -> KeyboardLayer.LETTERS
            }
            // Only the cursor's current caps mode matters. CAP_SENTENCES on the
            // inputType is almost always set, and treating that as "shift on"
            // capitalizes every letter after a dictation or mid-sentence tap.
            val initialShift = if (initialLayer == KeyboardLayer.LETTERS) {
                shiftFromCapsMode(info?.initialCapsMode ?: 0)
            } else {
                ShiftState.OFF
            }
            val action = editorAction(info?.imeOptions ?: EditorInfo.IME_ACTION_NONE)
            val variation = inputType and InputType.TYPE_MASK_VARIATION
            val leadingPunctuation = when (variation) {
                InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
                InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS,
                -> "@"

                InputType.TYPE_TEXT_VARIATION_URI -> "/"
                else -> ","
            }

            return KeyboardEditorConfig(
                sessionId = sessionId,
                initialLayer = initialLayer,
                initialShift = initialShift,
                returnKey = action.first,
                editorActionId = action.second,
                leadingPunctuation = leadingPunctuation,
                dictationAllowed = ImeInputPolicy.acceptsDictation(inputType),
                sensitive = ImeInputPolicy.isSensitive(inputType),
            )
        }

        private fun editorAction(imeOptions: Int): Pair<ReturnKeyKind, Int?> {
            if (imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0) {
                return ReturnKeyKind.ENTER to null
            }
            return when (imeOptions and EditorInfo.IME_MASK_ACTION) {
                EditorInfo.IME_ACTION_GO -> ReturnKeyKind.GO to EditorInfo.IME_ACTION_GO
                EditorInfo.IME_ACTION_NEXT -> ReturnKeyKind.NEXT to EditorInfo.IME_ACTION_NEXT
                EditorInfo.IME_ACTION_SEARCH -> ReturnKeyKind.SEARCH to EditorInfo.IME_ACTION_SEARCH
                EditorInfo.IME_ACTION_SEND -> ReturnKeyKind.SEND to EditorInfo.IME_ACTION_SEND
                EditorInfo.IME_ACTION_DONE -> ReturnKeyKind.DONE to EditorInfo.IME_ACTION_DONE
                EditorInfo.IME_ACTION_PREVIOUS -> ReturnKeyKind.PREVIOUS to EditorInfo.IME_ACTION_PREVIOUS
                else -> ReturnKeyKind.ENTER to null
            }
        }
    }
}

/**
 * Enough of an editor to tell one apart from the next.
 *
 * `fieldId` alone would do for a single app, but it is only unique within a
 * window, so the package comes with it. The input type and IME action are in
 * here because they decide the layer, the return key and whether dictation is
 * offered at all — a field that comes back having changed one of those is a
 * different keyboard even if it is the same view.
 */
internal data class EditorIdentity(
    val fieldId: Int,
    val packageName: String?,
    val inputType: Int,
    val imeOptions: Int,
) {
    companion object {
        fun of(info: EditorInfo?): EditorIdentity = EditorIdentity(
            fieldId = info?.fieldId ?: 0,
            packageName = info?.packageName,
            inputType = info?.inputType ?: InputType.TYPE_NULL,
            imeOptions = info?.imeOptions ?: EditorInfo.IME_ACTION_NONE,
        )
    }
}

/**
 * Which `onStartInput` calls are a new editor and which are the same one being
 * handed back.
 *
 * Apps restart input on the field the user is already typing in, and they do
 * it constantly: `setText` from a `TextWatcher`, an input filter, emoji
 * processing, a span update, a mention highlighter. Compose does it too —
 * `TextInputServiceAndroid` restarts whenever the composing region changes
 * while the selection does not, which is exactly what `finishComposingText`
 * produces when the layer key is tapped mid-word.
 *
 * Treating those as new editors threw away everything the keyboard holds that
 * the editor does not — the layer, caps lock, an open emoji panel — because
 * all of it hangs off `KeyboardEditorConfig.sessionId`. Caps lock survived
 * exactly one letter: committing it changed the app's text, the app restarted
 * input, and shift went back to whatever the cursor's caps mode said. Tapping
 * `?123` was worse, because finishing the composing region *is* the edit that
 * causes the restart: the number layer appeared and the letters were back
 * before the next frame, which reads as a dead key.
 *
 * The framework flags a restart with `restarting`, and that would be the
 * obvious thing to branch on. This deliberately does not, because the flag is
 * the IME's weakest input: it is decided by the app's process and the system
 * server, an OEM framework is free to get it wrong, and every path that gets
 * it wrong reintroduces the bug. The editor's own identity answers the same
 * question without trusting anybody — two calls describing the same field are
 * the same field.
 *
 * The pairing with `onFinishInput` is what makes that safe. Moving to another
 * field always finishes the old input first (`InputMethodService.doStartInput`
 * only skips `doFinishInput` when restarting), and finishing clears the stored
 * identity, so a genuine field change still starts a new session even when two
 * fields look alike — an unavoidable case, since a view with no id reports
 * `fieldId` -1 like every other one.
 */
internal object EditorRestart {
    fun keepsSession(previous: EditorIdentity?, next: EditorIdentity): Boolean =
        previous == next
}
