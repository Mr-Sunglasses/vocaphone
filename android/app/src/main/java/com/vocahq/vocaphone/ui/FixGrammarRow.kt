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
) {
    var offering by remember { mutableStateOf(false) }
    val raw = settings.style == WritingStyle.RAW
    SettingsSwitchRow(
        title = "Fix grammar (English)",
        supporting = when {
            raw -> "Not applied to the Raw style."
            model.downloading -> listOfNotNull(
                "Downloading the grammar model",
                downloadSizeProgress(model.downloadedBytes, model.totalBytes),
            ).joinToString(" · ")
            model.failure != null -> model.failure
            model.ready -> "Common grammar slips, on this phone."
            else -> "Common grammar slips, on this phone. ${byteLabel(model.totalBytes)} download."
        },
        checked = settings.fixGrammar && model.ready && !raw,
        enabled = !raw && !model.downloading,
        onCheckedChange = { on ->
            when {
                !on -> onFixGrammar(false)
                model.ready -> onFixGrammar(true)
                else -> offering = true
            }
        },
    )
    if (offering) {
        AlertDialog(
            onDismissRequest = { offering = false },
            title = { Text("Download the grammar model?") },
            text = {
                Text(
                    "Fix grammar uses a ${byteLabel(model.totalBytes)} model that runs on this phone. " +
                        "Your words are corrected here and never sent anywhere. It fixes common " +
                        "English grammar and spelling slips, and can occasionally change a " +
                        "sentence that was already right.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    offering = false
                    onFixGrammar(true)
                }) { Text("Download") }
            },
            dismissButton = {
                TextButton(onClick = { offering = false }) { Text("Not now") }
            },
        )
    }
}
