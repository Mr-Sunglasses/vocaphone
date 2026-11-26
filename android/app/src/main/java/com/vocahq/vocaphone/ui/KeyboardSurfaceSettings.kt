package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.settings.ClipboardRetention

/**
 * The keyboard-surface rows (clipboard retention, layouts, key feedback,
 * one-handed mode), together so the settings screen's signature stays short.
 */
data class KeyboardSurfaceActions(
    val onClipboardRetention: (ClipboardRetention) -> Unit = {},
)
