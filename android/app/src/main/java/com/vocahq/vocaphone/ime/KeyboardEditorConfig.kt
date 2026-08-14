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
