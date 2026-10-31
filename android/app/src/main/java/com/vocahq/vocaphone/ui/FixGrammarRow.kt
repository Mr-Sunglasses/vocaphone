package com.vocahq.vocaphone.ui

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.local.GrammarModelState
import com.vocahq.vocaphone.local.byteLabel
import com.vocahq.vocaphone.local.downloadSizeProgress
import com.vocahq.vocaphone.settings.VocaPhoneSettings

/**
 * "Fix grammar (English)" in the Output group.
 *
 * The switch cannot be on without a verified model: turning it on while the
 * model is missing asks before a download and says how big it is, and the
 * setting is only written once the files have passed their checksums.
 */
@Composable
internal fun FixGrammarRow(
    settings: VocaPhoneSettings,
    model: GrammarModelState,
    onFixGrammar: (Boolean) -> Unit,
    onCancelDownload: () -> Unit,
) {
    val raw = settings.style == WritingStyle.RAW
    GrammarModelSwitchRow(
        title = "Fix grammar (English)",
        description = "Common grammar slips, on this phone.",
        unavailable = "Not applied to the Raw style.".takeIf { raw },
        on = settings.fixGrammar,
        model = model,
        onChange = onFixGrammar,
        onCancelDownload = onCancelDownload,
    )
}

/**
 * "Check grammar" in the keyboard's Typing group: the same model, offered
 * for what is typed. It shares [FixGrammarRow]'s download, so whichever is
 * turned on first fetches the model and the other is then a plain switch.
 */
@Composable
internal fun TypingGrammarRow(
    settings: VocaPhoneSettings,
    model: GrammarModelState,
    onTypingGrammar: (Boolean) -> Unit,
    onCancelDownload: () -> Unit,
) {
    GrammarModelSwitchRow(
        title = "Check grammar (English)",
        description = "Offers a fix in the toolbar when you pause. Nothing changes until you tap it.",
        unavailable = "Needs suggestions turned on.".takeIf { !settings.suggestionsEnabled },
        on = settings.typingGrammar,
        model = model,
        onChange = onTypingGrammar,
        onCancelDownload = onCancelDownload,
    )
}

@Composable
private fun GrammarModelSwitchRow(
    title: String,
    description: String,
    unavailable: String?,
    on: Boolean,
    model: GrammarModelState,
    onChange: (Boolean) -> Unit,
    onCancelDownload: () -> Unit,
) {
    var offering by remember { mutableStateOf(false) }
    SettingsSwitchRow(
        title = title,
        supporting = when {
            unavailable != null -> unavailable
            model.downloading -> listOfNotNull(
                "Downloading the grammar model",
                downloadSizeProgress(model.downloadedBytes, model.totalBytes),
            ).joinToString(" · ")
            model.failure != null -> model.failure
            model.ready -> description
            else -> "$description ${byteLabel(model.totalBytes)} download."
        },
        checked = on && model.ready && unavailable == null,
        enabled = unavailable == null && !model.downloading,
        onCheckedChange = { checked ->
            when {
                !checked -> onChange(false)
                model.ready -> onChange(true)
                else -> offering = true
            }
        },
    )
    // The switch is disabled while the files arrive, so this is the one way to
    // change your mind about a 28 MB download.
    if (model.downloading) {
        SettingsGroupContent {
            TextButton(onClick = onCancelDownload) { Text("Cancel download") }
        }
    }
    if (offering) {
        AlertDialog(
            onDismissRequest = { offering = false },
            title = { Text("Download the grammar model?") },
            text = {
                Text(
                    "Grammar checking uses a ${byteLabel(model.totalBytes)} model that runs on this " +
                        "phone. Your words are checked here and never sent anywhere. It fixes common " +
                        "English grammar and spelling slips, and can occasionally change a " +
                        "sentence that was already right.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    offering = false
                    onChange(true)
                }) { Text("Download") }
            },
            dismissButton = {
                TextButton(onClick = { offering = false }) { Text("Not now") }
            },
        )
    }
}
