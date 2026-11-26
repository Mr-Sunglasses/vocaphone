package com.vocahq.vocaphone.ui

import androidx.compose.runtime.Composable
import com.vocahq.vocaphone.settings.ClipboardRetention
import com.vocahq.vocaphone.settings.VocaPhoneSettings

/**
 * The keyboard-surface rows (clipboard retention, layouts, key feedback,
 * one-handed mode), together so the settings screen's signature stays short.
 */
data class KeyboardSurfaceActions(
    val onClipboardRetention: (ClipboardRetention) -> Unit = {},
    val onKeyHaptics: (Boolean) -> Unit = {},
    val onKeyPopup: (Boolean) -> Unit = {},
    val onSpaceCursor: (Boolean) -> Unit = {},
    val onEmojiSuggestions: (Boolean) -> Unit = {},
)

/** Gboard's "Preferences › Keys" switches the keyboard did not have its own copy of. */
@Composable
internal fun KeyPressSettingsGroup(settings: VocaPhoneSettings, actions: KeyboardSurfaceActions) {
    SettingsGroup(title = "Keys") {
        SettingsSwitchRow(
            title = "Haptic feedback on keypress",
            supporting = "A light tap with each key. Also needs the system's touch feedback.",
            checked = settings.keyHapticsEnabled,
            onCheckedChange = actions.onKeyHaptics,
        )
        SettingsDivider()
        SettingsSwitchRow(
            title = "Popup on keypress",
            supporting = "Show the letter above your finger.",
            checked = settings.keyPopupEnabled,
            onCheckedChange = actions.onKeyPopup,
        )
        SettingsDivider()
        SettingsSwitchRow(
            title = "Space-bar cursor control",
            supporting = "Hold the space bar, then slide to move the cursor.",
            checked = settings.spaceCursorEnabled,
            onCheckedChange = actions.onSpaceCursor,
        )
        SettingsDivider()
        SettingsSwitchRow(
            title = "Emoji suggestions",
            supporting = "Offer 🍕 when you type pizza.",
            checked = settings.emojiSuggestionsEnabled,
            onCheckedChange = actions.onEmojiSuggestions,
        )
    }
}
