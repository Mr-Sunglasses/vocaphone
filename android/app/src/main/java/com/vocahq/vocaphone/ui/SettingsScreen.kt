package com.vocahq.vocaphone.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.core.MicrophonePreference
import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.settings.AudioRetention
import com.vocahq.vocaphone.settings.KeyboardHeight
import com.vocahq.vocaphone.settings.VocaPhoneSettings

private enum class SettingsPage(val title: String) {
    HOME("Settings"),
    MODELS("Models"),
    KEYBOARD("Keyboard"),
    DICTATION("Dictation"),
    CONNECTION("Connection"),
    ABOUT("About"),
}

@Composable
fun SettingsScreen(
    settings: VocaPhoneSettings,
    setup: SetupStatus,
    microphone: MicrophoneStatus,
    onLanguage: (TranscriptionLanguage) -> Unit,
    onStyle: (WritingStyle) -> Unit,
    onMicrophone: (MicrophonePreference) -> Unit,
    onAudioRetention: (AudioRetention) -> Unit,
    onTranscriptionQuality: (TranscriptionQuality) -> Unit,
    onCustomVocabulary: (String) -> Unit,
    onNumberRow: (Boolean) -> Unit,
    onKeyboardHeight: (KeyboardHeight) -> Unit,
    onSuggestions: (Boolean) -> Unit,
    onClipboardChip: (Boolean) -> Unit,
    localModels: LocalModelState,
    onLocalTranscriptionEnabled: (Boolean) -> Unit,
    onLocalModel: (LocalModelDescriptor) -> Unit,
    onDownloadLocalModel: (LocalModelDescriptor) -> Unit,
    onDownloadAndUseLocalModel: (LocalModelDescriptor) -> Unit,
    onCancelLocalModelDownload: () -> Unit,
    onDeleteLocalModel: (LocalModelDescriptor) -> Unit,
    onOpenGateway: () -> Unit,
    onTryDictation: () -> Unit,
    diagnosticEvents: () -> String,
    onClearDiagnosticEvents: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val appInfo = remember { context.readAppInfo() }
    var pickingLanguage by remember { mutableStateOf(false) }
    var page by remember { mutableStateOf(SettingsPage.HOME) }
    val localModel = LocalModelCatalog.find(settings.localModelId)

    BackHandler(enabled = page != SettingsPage.HOME) { page = SettingsPage.HOME }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(if (page == SettingsPage.HOME) CategorySpacing else SectionSpacing),
    ) {
        if (page != SettingsPage.HOME) {
            TextButton(onClick = { page = SettingsPage.HOME }) { Text("Back") }
            Text(page.title, style = MaterialTheme.typography.headlineSmall)
        }

        when (page) {
            SettingsPage.HOME -> {
                SpeechSourceCard(
                    settings = settings,
                    onTryDictation = onTryDictation,
                    onOpenGateway = onOpenGateway,
                    onLocalTranscriptionEnabled = onLocalTranscriptionEnabled,
                )
                ImeSetupCard(setup.ime)
                val languageRestriction = ModelLanguageSupport.restriction(
                    settings.activeModelLanguages,
                    settings.activeModelDetectsLanguage,
                    onDevice = settings.localTranscriptionEnabled,
                )
                Section(
                    "Language",
                    supporting = listOfNotNull(settings.effectiveLanguage.detail, languageRestriction)
                        .joinToString("\n"),
                ) {
                    InfoRow(label = "Language", value = settings.effectiveLanguage.displayName)
                    SecondaryButton("Change language", onClick = { pickingLanguage = true })
                }
                SettingsMenuRow(
                    title = "Models",
                    supporting = localModel?.displayName ?: "Download a model for this phone",
                    onClick = { page = SettingsPage.MODELS },
                )
                SettingsMenuRow(
                    title = "Keyboard",
                    supporting = buildString {
                        append(settings.keyboardHeight.displayName)
                        if (settings.numberRowEnabled) append(" · number row")
                    },
                    onClick = { page = SettingsPage.KEYBOARD },
                )
                SettingsMenuRow(
                    title = "Dictation",
                    supporting = "${settings.style.displayName} · ${settings.microphone.displayName}",
                    onClick = { page = SettingsPage.DICTATION },
                )
                SettingsMenuRow(
                    title = "Connection",
                    supporting = settings.gatewayUrl.ifEmpty { "No gateway configured" },
                    onClick = { page = SettingsPage.CONNECTION },
                )
                SettingsMenuRow(
                    title = "About",
                    supporting = "VocaPhone ${appInfo.versionName}",
                    onClick = { page = SettingsPage.ABOUT },
                )
            }

            SettingsPage.MODELS -> {
                LocalModelPicker(
                    state = localModels,
                    selectedModelId = settings.localModelId,
                    onSelect = onLocalModel,
                    onDownload = onDownloadLocalModel,
                    onDownloadAndUse = onDownloadAndUseLocalModel,
                    onCancelDownload = onCancelLocalModelDownload,
                    onDelete = onDeleteLocalModel,
                )
                Section(
                    title = "Accuracy",
                    supporting = "${settings.transcriptionQuality.detail}\n" +
                        "Applies to models running on this phone. The gateway decides for itself.",
                ) {
                    ChipChoiceRow(
                        options = TranscriptionQuality.entries,
                        selected = settings.transcriptionQuality,
                        label = { it.displayName },
                        onSelect = onTranscriptionQuality,
                    )
                }
                CustomVocabularySection(
                    vocabulary = settings.customVocabulary,
                    onSave = onCustomVocabulary,
                    unsupportedModel = localModel
                        ?.takeIf { settings.localTranscriptionEnabled && !it.supportsCustomVocabulary }
                        ?.displayName,
                )
            }

            SettingsPage.KEYBOARD -> {
                ImeSetupCard(setup.ime)
                Section("Layout") {
                    SettingToggle(
                        title = "Number row",
                        detail = "Show 1-0 above the letter keys.",
                        checked = settings.numberRowEnabled,
                        onCheckedChange = onNumberRow,
                    )
                    Text("Height", style = MaterialTheme.typography.bodyMedium)
                    ChipChoiceRow(
                        options = KeyboardHeight.entries,
                        selected = settings.keyboardHeight,
                        label = { it.displayName },
                        onSelect = onKeyboardHeight,
                    )
                    SettingToggle(
                        title = "Suggestions",
                        detail = "Local English word completions and next-word guesses. " +
                            "Reads a short window of text before the cursor. Off in passwords.",
                        checked = settings.suggestionsEnabled,
                        onCheckedChange = onSuggestions,
                    )
                    SettingToggle(
                        title = "Clipboard chip",
                        detail = "Clipboard icon plus a preview of the current clip. " +
                            "It goes away after you use it once.",
                        checked = settings.clipboardChipEnabled,
                        onCheckedChange = onClipboardChip,
                    )
                }
            }

            SettingsPage.DICTATION -> {
                Section(
                    title = "Writing style",
                    supporting = "${settings.style.detail}\n${settings.style.example}",
                ) {
                    ChipChoiceRow(
                        options = WritingStyle.entries,
                        selected = settings.style,
                        label = { it.displayName },
                        onSelect = onStyle,
                    )
                }
                MicrophoneSection(
                    selected = settings.microphone,
                    status = microphone,
                    onSelect = onMicrophone,
                )
                Section(
                    title = "Audio retention",
                    supporting = "Successful dictations delete their audio immediately. A " +
                        "failed one keeps it only this long, so Retry still works.",
                ) {
                    ChipChoiceRow(
                        options = AudioRetention.entries,
                        selected = settings.audioRetention,
                        label = { it.displayName },
                        onSelect = onAudioRetention,
                    )
                }
            }

            SettingsPage.CONNECTION -> {
                FeaturedCard {
                    Text(
                        buildString {
                            append("Engine: ")
                            append(settings.lastEngine.ifEmpty { "unknown" })
                            append(if (settings.lastEngineReady) " (ready)" else " (not ready)")
                            append("\nStreaming: ")
                            append(if (settings.lastStreamingSupported) "supported" else "batch upload")
                        },
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    SecondaryButton("Gateway settings", onClick = onOpenGateway)
                    SecondaryButton(
                        text = "Open web dashboard",
                        onClick = { context.openUrl(settings.gatewayUrl) },
                        enabled = settings.gatewayUrl.isNotEmpty(),
                    )
                    Text(
                        "The dashboard is where you pick a speech-to-text model for the gateway.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            SettingsPage.ABOUT -> {
                Section("Privacy") {
                    Text(
                        "VocaPhone's keyboard inserts through Android's text connection. " +
                            "Dictation does not read the field. With Suggestions on, the keyboard " +
                            "reads about 32 characters before the cursor so it can guess the next " +
                            "word; that text stays on this phone and is never logged. The clipboard " +
                            "chip reads the current clip only while the keyboard is visible, and " +
                            "it goes away after you paste once. Audio " +
                            "goes to on-device transcription or the gateway you configured. There is " +
                            "no cloud transcription, no analytics, and nothing is written to the " +
                            "clipboard unless you tap Copy.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                Section("Device") {
                    InfoRow("Android", "${appInfo.androidRelease} (SDK ${appInfo.sdkInt})")
                    InfoRow("Device", appInfo.device)
                    InfoRow("Installed from", appInfo.installedFrom)
                    InfoRow("Package", appInfo.packageName)
                    InfoRow(
                        "Engine",
                        settings.lastEngine.ifEmpty { "unknown" } +
                            if (settings.lastEngineReady) " (ready)" else " (not ready)",
                    )
                    InfoRow(
                        "Setup",
                        if (setup.isReadyToDictate) {
                            "complete"
                        } else {
                            "${setup.completedStepCount} of ${setup.stepCount} steps"
                        },
                    )
                    Text(
                        "Diagnostics contain only bounded timestamps, state transitions, " +
                            "error categories and build/source context. They never include " +
                            "transcripts, typed text, audio, gateway hosts or tokens.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        SecondaryButton(
                            text = "Copy diagnostics",
                            onClick = {
                                context.copyDiagnostics(
                                    diagnosticsReport(appInfo, settings, setup, diagnosticEvents())
                                )
                            },
                            modifier = Modifier.weight(1f),
                        )
                        SecondaryButton(
                            text = "Project page",
                            onClick = { context.openUrl(PROJECT_URL) },
                            modifier = Modifier.weight(1f),
                        )
                    }
                    TextButton(onClick = onClearDiagnosticEvents) { Text("Clear event log") }
                }
            }
        }
    }

    if (pickingLanguage) {
        LanguagePickerSheet(
            selected = settings.effectiveLanguage,
            modelLanguages = settings.activeModelLanguages,
            detectsLanguageAutomatically = settings.activeModelDetectsLanguage,
            onDevice = settings.localTranscriptionEnabled,
            onSelect = onLanguage,
            onDismiss = { pickingLanguage = false },
        )
    }
}

@Composable
private fun SpeechSourceCard(
    settings: VocaPhoneSettings,
    onTryDictation: () -> Unit,
    onOpenGateway: () -> Unit,
    onLocalTranscriptionEnabled: (Boolean) -> Unit,
) {
    val localModel = LocalModelCatalog.find(settings.localModelId)
    val usingLocal = settings.localTranscriptionEnabled && localModel != null
    FeaturedCard {
        Text(
            if (usingLocal) "On this phone" else if (settings.isConfigured) "Gateway" else "No speech source yet",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
        )
        Text(
            when {
                usingLocal -> localModel.displayName
                settings.isConfigured -> settings.gatewayUrl
                else -> "Open Models to download one, or add a gateway."
            },
            style = MaterialTheme.typography.titleMedium,
        )
        if (usingLocal) {
            Text(
                localModel.catalogMeta(),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else if (settings.isConfigured) {
            Text(
                buildString {
                    append(settings.lastEngine.ifEmpty { "unknown engine" })
                    append(if (settings.lastEngineReady) " · ready" else " · not ready")
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        SettingToggle(
            title = "Use on-device transcription",
            detail = "Downloads are checked with SHA-256 before they are accepted.",
            checked = settings.localTranscriptionEnabled,
            onCheckedChange = onLocalTranscriptionEnabled,
        )
        PrimaryButton("Try dictation", onClick = onTryDictation, modifier = Modifier.fillMaxWidth())
        if (settings.isConfigured) {
            TextButton(onClick = onOpenGateway, contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) {
                Text("Gateway settings")
            }
        }
    }
}

/**
 * Which microphone dictation asks for. Options the hardware cannot satisfy stay
 * visible but greyed, and the whole row locks while a dictation is running: the
 * input is chosen when the recorder is built, so a mid-recording change would be
 * a promise the current dictation cannot keep.
 */
@Composable
private fun MicrophoneSection(
    selected: MicrophonePreference,
    status: MicrophoneStatus,
    onSelect: (MicrophonePreference) -> Unit,
) {
    val attached = selected in status.available
    Section(
        title = "Microphone",
        supporting = if (attached) selected.detail else selected.unavailableDetail,
    ) {
        ChipChoiceRow(
            options = MicrophonePreference.entries,
            selected = selected,
            label = { it.displayName },
            onSelect = onSelect,
            enabled = { status.changeable && (it in status.available || it == selected) },
        )

        InfoRow("Input in use", status.inUseLabel(selected))

        Text(
            if (!status.changeable) {
                "Finish the current dictation before changing microphones."
            } else {
                "Greyed-out options have no matching microphone connected. " +
                    "Android has the final say on routing, so the input above " +
                    "is what capture actually used."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * The list is edited locally and saved on request rather than on every
 * keystroke: the terms are parsed at inference time, and a half-typed name
 * being persisted mid-word is a spelling nobody asked to be biased toward.
 */
@Composable
private fun CustomVocabularySection(
    vocabulary: String,
    onSave: (String) -> Unit,
    unsupportedModel: String?,
) {
    var draft by remember(vocabulary) { mutableStateOf(vocabulary) }
    val terms = remember(draft) { CustomVocabulary.terms(draft) }

    Section(
        title = "Custom words",
        supporting = "Names, places and jargon an on-device Whisper model is " +
            "unlikely to know. One per line, or separated by commas.",
    ) {
        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Words and phrases") },
            placeholder = { Text("Kanishk\nVocaHQ\nTailscale") },
            minLines = 3,
            maxLines = 6,
        )
        Text(
            if (terms.isEmpty()) {
                "No custom words. Transcription is unchanged."
            } else {
                "${terms.size} word${if (terms.size == 1) "" else "s"} will bias the decoder. " +
                    "This nudges spelling rather than guaranteeing it, and a very long " +
                    "list starts to crowd out the speech itself."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (unsupportedModel != null && terms.isNotEmpty()) {
            Text(
                "$unsupportedModel cannot use these words. Only Whisper models take a " +
                    "vocabulary; the list is kept for when you switch back to one.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
        }
        SecondaryButton(
            text = "Save words",
            onClick = { onSave(draft) },
            enabled = draft != vocabulary,
        )
    }
}

private fun Context.copyDiagnostics(text: String) {
    val clipboard = getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("VocaPhone diagnostics", text))
}

/** No browser is a plausible state on a stripped-down ROM, so failure is silent. */
private fun Context.openUrl(url: String) {
    runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
}
