package com.vocahq.vocaphone.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
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
import com.vocahq.vocaphone.settings.SplitKeyboard
import com.vocahq.vocaphone.settings.VocaPhoneSettings

enum class SettingsPage(val title: String) {
    HOME("Settings"),
    MODELS("Models"),
    KEYBOARD("Keyboard"),
    DICTATION("Dictation"),
    CONNECTION("Speech"),
    ABOUT("About"),
    ;

    companion object {
        fun fromExtra(value: String?): SettingsPage = when (value?.lowercase()) {
            "models" -> MODELS
            "keyboard" -> KEYBOARD
            "dictation" -> DICTATION
            "connection" -> CONNECTION
            "about" -> ABOUT
            else -> HOME
        }
    }
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
    onSplitKeyboard: (SplitKeyboard) -> Unit,
    onSuggestions: (Boolean) -> Unit,
    onCorrections: (Boolean) -> Unit,
    onNumberKeyHints: (Boolean) -> Unit,
    onAsciiEmoji: (Boolean) -> Unit,
    onSwipeTyping: (Boolean) -> Unit,
    onClipboardChip: (Boolean) -> Unit,
    onClipboardHistory: (Boolean) -> Unit,
    onClearClipboardHistory: () -> Unit,
    localModels: LocalModelState,
    onLocalTranscriptionEnabled: (Boolean) -> Unit,
    onLocalModel: (LocalModelDescriptor) -> Unit,
    onDownloadLocalModel: (LocalModelDescriptor) -> Unit,
    onDownloadAndUseLocalModel: (LocalModelDescriptor) -> Unit,
    onCancelLocalModelDownload: () -> Unit,
    onDeleteLocalModel: (LocalModelDescriptor) -> Unit,
    onOpenGateway: () -> Unit,
    diagnosticEvents: () -> String,
    onClearDiagnosticEvents: () -> Unit,
    onTelemetryEnabled: (Boolean) -> Unit,
    telemetryPayload: () -> String,
    telemetryPendingCount: () -> Int,
    telemetryDeliveryStatus: () -> String,
    page: SettingsPage,
    onPageChange: (SettingsPage) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val appInfo = remember { context.readAppInfo() }
    val onDevice = context.readOnDeviceDiagnostics(localModels.downloaded)
    var pickingLanguage by remember { mutableStateOf(false) }
    val localModel = LocalModelCatalog.find(settings.localModelId)

    BackHandler(enabled = page != SettingsPage.HOME) { onPageChange(SettingsPage.HOME) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(SectionSpacing),
    ) {
        when (page) {
            SettingsPage.HOME -> {
                SpeechSourceCard(
                    settings = settings,
                    onOpenGateway = onOpenGateway,
                    onOpenModels = { onPageChange(SettingsPage.MODELS) },
                    onLocalTranscriptionEnabled = onLocalTranscriptionEnabled,
                )
                val languageRestriction = ModelLanguageSupport.restriction(
                    settings.activeModelLanguages,
                    settings.activeModelDetectsLanguage,
                    onDevice = settings.localTranscriptionEnabled,
                )
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SettingsMenuRow(
                        title = "Language",
                        supporting = listOfNotNull(
                            settings.effectiveLanguage.displayName,
                            languageRestriction,
                        ).joinToString(" · "),
                        icon = R.drawable.ic_language,
                        onClick = { pickingLanguage = true },
                    )
                    SettingsMenuRow(
                        title = "Models",
                        supporting = when {
                            !settings.localTranscriptionEnabled ->
                                "Off while you use a gateway"
                            localModel != null -> localModel.displayName
                            else -> "Download a model for this phone"
                        },
                        icon = R.drawable.ic_models,
                        onClick = { onPageChange(SettingsPage.MODELS) },
                    )
                    SettingsMenuRow(
                        title = "Keyboard",
                        supporting = buildString {
                            append(
                                when {
                                    setup.ime.selected -> "Selected"
                                    setup.ime.enabled -> "Enabled"
                                    else -> "Not enabled"
                                },
                            )
                            append(" · ")
                            append(settings.keyboardHeight.displayName)
                            if (settings.numberRowEnabled) append(" · number row")
                            if (settings.splitKeyboard != SplitKeyboard.AUTO) {
                                append(" · split ${settings.splitKeyboard.displayName.lowercase()}")
                            }
                        },
                        icon = R.drawable.ic_keyboard,
                        onClick = { onPageChange(SettingsPage.KEYBOARD) },
                    )
                SettingsMenuRow(
                    title = "Dictation",
                    supporting = "${settings.style.displayName} · ${settings.microphone.displayName}",
                    icon = R.drawable.ic_dictation,
                    onClick = { onPageChange(SettingsPage.DICTATION) },
                )
                SettingsMenuRow(
                        title = "About",
                        supporting = "VocaPhone ${appInfo.versionName}",
                        icon = R.drawable.ic_about,
                        onClick = { onPageChange(SettingsPage.ABOUT) },
                    )
                }
            }

            SettingsPage.MODELS -> {
                LocalModelPicker(
                    state = localModels,
                    selectedModelId = settings.localModelId,
                    usingGateway = !settings.localTranscriptionEnabled,
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
                    Text("Split keyboard", style = MaterialTheme.typography.bodyMedium)
                    ChipChoiceRow(
                        options = SplitKeyboard.entries,
                        selected = settings.splitKeyboard,
                        label = { it.displayName },
                        onSelect = onSplitKeyboard,
                    )
                    Text(
                        "Auto splits when the keyboard is at least 600 dp wide, " +
                            "like a tablet or an unfolded foldable. " +
                            "A phone-sized portrait keyboard stays in one piece.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    SettingToggle(
                        title = "Suggestions",
                        detail = "Local English word completions and next-word guesses. " +
                            "Reads a short window of text around the cursor. Off in passwords.",
                        checked = settings.suggestionsEnabled,
                        onCheckedChange = onSuggestions,
                    )
                    SettingToggle(
                        title = "Corrections",
                        detail = "Offer nearby dictionary words in the toolbar. " +
                            "Tap a word, or a swipe alternative, to replace it.",
                        checked = settings.correctionsEnabled,
                        onCheckedChange = onCorrections,
                    )
                    SettingToggle(
                        title = "Number key hints",
                        detail = "Show the long-press symbol on 1-0 in a lighter color.",
                        checked = settings.numberKeyHintsEnabled,
                        onCheckedChange = onNumberKeyHints,
                    )
                    SettingToggle(
                        title = "Text emoticons",
                        detail = "Add an ASCII category to the emoji panel, like :) and ¯\\_(ツ)_/¯.",
                        checked = settings.asciiEmojiEnabled,
                        onCheckedChange = onAsciiEmoji,
                    )
                    SettingToggle(
                        title = "Swipe typing",
                        detail = "Glide across letter keys to enter a word. " +
                            "English only; there is no language pack to download.",
                        checked = settings.swipeTypingEnabled,
                        onCheckedChange = onSwipeTyping,
                    )
                    SettingToggle(
                        title = "Clipboard chip",
                        detail = "Clipboard icon plus a preview of the current clip. " +
                            "Tap to paste. Long press to dismiss it.",
                        checked = settings.clipboardChipEnabled,
                        onCheckedChange = onClipboardChip,
                    )
                    SettingToggle(
                        title = "Clipboard history",
                        detail = "Save recent text and images on this phone. Open them " +
                            "from the keyboard menu. Off in passwords.",
                        checked = settings.clipboardHistoryEnabled,
                        onCheckedChange = onClipboardHistory,
                    )
                    if (settings.clipboardHistory.isNotEmpty()) {
                        SecondaryButton(
                            "Clear clipboard history (${settings.clipboardHistory.size})",
                            onClick = onClearClipboardHistory,
                        )
                    }
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
                // Next to audio retention rather than under About: both answer
                // "what does this app keep or send", which is the question
                // someone is holding when they come looking for either.
                UsageReportingSection(
                    enabled = settings.telemetryEnabled,
                    onEnabled = onTelemetryEnabled,
                    payload = telemetryPayload,
                    pendingCount = telemetryPendingCount,
                    deliveryStatus = telemetryDeliveryStatus,
                )
            }

            SettingsPage.CONNECTION -> {
                SpeechSourceCard(
                    settings = settings,
                    onOpenGateway = onOpenGateway,
                    onOpenModels = { onPageChange(SettingsPage.MODELS) },
                    onLocalTranscriptionEnabled = onLocalTranscriptionEnabled,
                )
            }

            SettingsPage.ABOUT -> {
                AboutPage(
                    appInfo = appInfo,
                    settings = settings,
                    setup = setup,
                    localModel = localModel,
                    onDevice = onDevice,
                    diagnosticEvents = diagnosticEvents,
                    onClearDiagnosticEvents = onClearDiagnosticEvents,
                )
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


