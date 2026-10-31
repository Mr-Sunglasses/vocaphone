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
import com.vocahq.vocaphone.local.GrammarModelCatalog
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

/** What the Writing check group can ask for; one value rather than nine parameters. */
data class WritingSettingsActions(
    val onCheckWhileTyping: (Boolean) -> Unit = {},
    val onDownloadModel: () -> Unit = {},
    val onSureOnly: (Boolean) -> Unit = {},
    val onClarity: (Boolean) -> Unit = {},
    val onEngagement: (Boolean) -> Unit = {},
    val onDelivery: (Boolean) -> Unit = {},
    val onTone: (Boolean) -> Unit = {},
    val onTypoAutoFix: (Boolean) -> Unit = {},
    /** The system spell checker setting; null where it cannot be opened. */
    val onOpenSpellChecker: (() -> Unit)? = null,
    val onOpenEditor: () -> Unit = {},
)

/**
 * "Writing check (English)": Grammarly's keyboard, on this phone. Checking
 * while typing needs no download (the rules ship in the app); the grammar
 * model is an optional download that catches more, shared with dictation's
 * Fix grammar.
 */
@Composable
internal fun WritingCheckSettingsGroup(
    settings: VocaPhoneSettings,
    model: GrammarModelState,
    actions: WritingSettingsActions,
    onCancelDownload: () -> Unit,
) {
    SettingsGroup(
        title = "Writing check (English)",
        footer = "Runs on this phone. Nothing you type is sent anywhere.",
        learnMore = SettingsHelp.writing,
    ) {
        SettingsSwitchRow(
            title = "Check while typing",
            supporting = when {
                !settings.suggestionsEnabled -> "Needs suggestions turned on."
                else -> "Suggestions in the toolbar when you pause. Nothing changes until you tap."
            },
            checked = settings.typingGrammar && settings.suggestionsEnabled,
            enabled = settings.suggestionsEnabled,
            onCheckedChange = actions.onCheckWhileTyping,
        )
        SettingsDivider()
        SettingsActionRow(
            title = "Check text in VocaPhone",
            supporting = "Paste or write something and see every suggestion, a score and how it sounds.",
            onClick = actions.onOpenEditor,
        )
        if (GrammarModelCatalog.available) {
            SettingsDivider()
            GrammarModelRow(model, actions.onDownloadModel, onCancelDownload)
            SettingsDivider()
            SettingsSwitchRow(
                title = "Only sure fixes",
                supporting = "Fewer grammar suggestions, each more likely to be right.",
                checked = settings.grammarSureOnly,
                onCheckedChange = actions.onSureOnly,
            )
        }
        SettingsDivider()
        SettingsSwitchRow(
            title = "Clarity",
            supporting = "Wordy phrases, passive voice, long sentences.",
            checked = settings.writingClarity,
            onCheckedChange = actions.onClarity,
        )
        SettingsDivider()
        SettingsSwitchRow(
            title = "Engagement",
            supporting = "“Very good” → “great”, and words used too often.",
            checked = settings.writingEngagement,
            onCheckedChange = actions.onEngagement,
        )
        SettingsDivider()
        SettingsSwitchRow(
            title = "Delivery",
            supporting = "Hedging like “I just wanted to”.",
            checked = settings.writingDelivery,
            onCheckedChange = actions.onDelivery,
        )
        SettingsDivider()
        SettingsSwitchRow(
            title = "Tone",
            supporting = "Says how your text sounds: friendly, formal, urgent…",
            checked = settings.writingTone,
            onCheckedChange = actions.onTone,
        )
        SettingsDivider()
        SettingsSwitchRow(
            title = "Fix obvious typos as I type",
            supporting = "“recieve” → “receive”, “dont” → “don't”, with Undo in the toolbar.",
            checked = settings.typoAutoFix,
            enabled = settings.typingGrammar,
            onCheckedChange = actions.onTypoAutoFix,
        )
        actions.onOpenSpellChecker?.let { open ->
            SettingsDivider()
            SettingsActionRow(
                title = "Underline mistakes in other apps",
                supporting = "Choose VocaPhone as the system spell checker. Works with any keyboard.",
                onClick = open,
                external = true,
            )
        }
    }
}

/**
 * The grammar model as its own row: what it adds, its size, and a download
 * that asks first. Turning it off is Fix grammar's and Check grammar's
 * business, so there is no delete here.
 */
@Composable
private fun GrammarModelRow(
    model: GrammarModelState,
    onDownload: () -> Unit,
    onCancelDownload: () -> Unit,
) {
    var offering by remember { mutableStateOf(false) }
    when {
        model.downloading -> SettingsActionRow(
            title = "Grammar model",
            supporting = listOfNotNull(
                "Downloading",
                downloadSizeProgress(model.downloadedBytes, model.totalBytes),
            ).joinToString(" · "),
            onClick = onCancelDownload,
        )
        model.ready -> SettingsInfoRow(label = "Grammar model", value = "On this phone")
        else -> SettingsActionRow(
            title = "Download the grammar model",
            supporting = model.failure ?: "Catches more grammar slips. ${byteLabel(model.totalBytes)}, runs on this phone.",
            onClick = { offering = true },
        )
    }
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
                    "Writing check works without it. The ${byteLabel(model.totalBytes)} model runs on " +
                        "this phone and catches more grammar slips, like “he don't know”. Your words " +
                        "are checked here and never sent anywhere.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    offering = false
                    onDownload()
                }) { Text("Download") }
            },
            dismissButton = {
                TextButton(onClick = { offering = false }) { Text("Not now") }
            },
        )
    }
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
