package com.vocahq.vocaphone.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import com.vocahq.vocaphone.ime.KeyboardLanguages
import com.vocahq.vocaphone.ime.TypingLayout
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
    val onKeyboardLayouts: (List<String>) -> Unit = {},
)

/**
 * Settings › Keyboard › Languages: which typing layouts the language key and
 * a sideways swipe on the space bar cycle through. Nothing chosen yet shows
 * the layouts for the phone's languages, which is what the keyboard uses.
 */
@Composable
internal fun KeyboardLanguagesSettingsGroup(settings: VocaPhoneSettings, actions: KeyboardSurfaceActions) {
    val tags = remember { KeyboardLanguages.deviceLanguageTags() }
    val enabled = KeyboardLanguages.enabled(settings.keyboardLayouts, tags)
    SettingsGroup(
        title = "Languages",
        footer = "With more than one on, tap the globe key or swipe sideways on the space bar to switch. " +
            "Suggestions, swipe typing and corrections are English only.",
    ) {
        KeyboardLanguages.catalogue.forEachIndexed { index, layout ->
            if (index > 0) SettingsDivider()
            val on = enabled.any { it.id == layout.id }
            SettingsSwitchRow(
                title = layout.displayName,
                supporting = layoutArrangement(layout),
                checked = on,
                // The last one on cannot be turned off: a keyboard needs a layout.
                enabled = !(on && enabled.size == 1),
                onCheckedChange = { checked ->
                    actions.onKeyboardLayouts(KeyboardLanguages.toggled(enabled, layout.id, checked))
                },
            )
        }
    }
}

private fun layoutArrangement(layout: TypingLayout): String =
    layout.rows.first().take(6).uppercase().let { name ->
        when (name) {
            "QWERTY", "QWERTZ", "AZERTY" -> name
            else -> "ЙЦУКЕН"
        }
    }

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
