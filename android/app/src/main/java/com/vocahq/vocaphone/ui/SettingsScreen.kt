package com.vocahq.vocaphone.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.core.DictationTone
import com.vocahq.vocaphone.core.MicrophonePreference
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
import com.vocahq.vocaphone.telemetry.TelemetryInspectPayload
import kotlin.math.abs
import kotlin.math.sin

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
    onDictationTone: (DictationTone) -> Unit,
    onPreviewDictationTone: (DictationTone) -> Unit,
    tonePreviewListening: Boolean,
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
    telemetryInspect: () -> TelemetryInspectPayload,
    telemetryPendingCount: () -> Int,
    telemetryDeliveryStatus: () -> String,
    page: SettingsPage,
    onPageChange: (SettingsPage) -> Unit,
    openLanguagePicker: Boolean = false,
    onLanguagePickerOpened: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val appInfo = remember { context.readAppInfo() }
    val onDevice = context.readOnDeviceDiagnostics(localModels.downloaded)
    var pickingLanguage by remember { mutableStateOf(false) }
    val localModel = LocalModelCatalog.find(settings.localModelId)

    LaunchedEffect(openLanguagePicker) {
        if (openLanguagePicker) {
            pickingLanguage = true
            onLanguagePickerOpened()
        }
    }

    BackHandler(enabled = page != SettingsPage.HOME) { onPageChange(SettingsPage.HOME) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(SectionSpacing),
    ) {
        when (page) {
            SettingsPage.HOME -> {
                SpeechSourceCard(
                    settings = settings,
                    onOpenGateway = onOpenGateway,
                    onLocalTranscriptionEnabled = onLocalTranscriptionEnabled,
                )
                SettingsMenuGroup {
                    SettingsMenuRow(
                        title = "Language",
                        supporting = settings.effectiveLanguage.displayName,
                        icon = R.drawable.ic_language,
                        onClick = { pickingLanguage = true },
                    )
                    SettingsMenuDivider()
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
                    SettingsMenuDivider()
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
                    SettingsMenuDivider()
                    SettingsMenuRow(
                        title = "Dictation",
                        supporting = "${settings.style.displayName} · ${settings.dictationTone.displayName} · ${settings.microphone.displayName}",
                        icon = R.drawable.ic_dictation,
                        onClick = { onPageChange(SettingsPage.DICTATION) },
                    )
                    SettingsMenuDivider()
                    SettingsMenuRow(
                        title = "About",
                        supporting = "VocaPhone ${appInfo.versionName}",
                        icon = R.drawable.ic_about,
                        onClick = { onPageChange(SettingsPage.ABOUT) },
                    )
                }
            }

            SettingsPage.MODELS -> {
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
                }
                Section("Typing") {
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
                }
                Section("Clipboard") {
                    SettingToggle(
                        title = "Clipboard chip",
                        detail = "Clipboard icon plus a preview of the current clip. " +
                            "Tap to paste. Tap the × to dismiss it.",
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
                        DestructiveButton(
                            "Clear clipboard history (${settings.clipboardHistory.size})",
                            onClick = onClearClipboardHistory,
                        )
                    }
                }
            }

            SettingsPage.DICTATION -> {
                Section(title = "Writing style") {
                    SettingDropdown(
                        options = WritingStyle.entries,
                        selected = settings.style,
                        label = { it.displayName },
                        detail = { it.detail },
                        onSelect = onStyle,
                    )
                    Text(
                        settings.style.example,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Section(
                    title = "Dictation tone",
                    supporting = if (settings.dictationTone.playsCues) {
                        "Start and stop cues when dictation turns on and off."
                    } else {
                        "Off plays nothing."
                    },
                ) {
                    SettingDropdown(
                        options = DictationTone.entries,
                        selected = settings.dictationTone,
                        label = { it.displayName },
                        detail = { it.detail },
                        onSelect = onDictationTone,
                    )
                    if (tonePreviewListening) {
                        TonePreviewMeter(active = true)
                    }
                    SecondaryButton(
                        text = if (tonePreviewListening) "Stop preview" else "Preview",
                        onClick = { onPreviewDictationTone(settings.dictationTone) },
                        enabled = settings.dictationTone.playsCues,
                    )
                }
                MicrophoneSection(
                    selected = settings.microphone,
                    status = microphone,
                    onSelect = onMicrophone,
                )
                Section(
                    title = "Audio and transcript retention",
                    supporting = "Successful dictations delete their audio immediately. A " +
                        "failed one keeps it only this long, so Retry still works.",
                ) {
                    ChipChoiceRow(
                        options = AudioRetention.entries,
                        selected = settings.audioRetention,
                        label = { it.displayName },
                        onSelect = onAudioRetention,
                    )
                    Text(
                        settings.audioRetention.detail,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                // Next to audio retention rather than under About: both answer
                // "what does this app keep or send", which is the question
                // someone is holding when they come looking for either.
                UsageReportingSection(
                    enabled = settings.telemetryEnabled,
                    onEnabled = onTelemetryEnabled,
                    inspect = telemetryInspect,
                    pendingCount = telemetryPendingCount,
                    deliveryStatus = telemetryDeliveryStatus,
                )
                CustomVocabularySection(
                    vocabulary = settings.customVocabulary,
                    onSave = onCustomVocabulary,
                    unsupportedModel = localModel
                        ?.takeIf { settings.localTranscriptionEnabled && !it.supportsCustomVocabulary }
                        ?.displayName,
                )
            }

            SettingsPage.CONNECTION -> {
                SpeechSourceCard(
                    settings = settings,
                    onOpenGateway = onOpenGateway,
                    onLocalTranscriptionEnabled = onLocalTranscriptionEnabled,
                    showTitle = false,
                    showGatewayActions = false,
                )
                SettingsMenuGroup {
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
                    SettingsMenuDivider()
                    SettingsMenuRow(
                        title = "Gateway",
                        supporting = if (settings.isConfigured) {
                            "Saved. Opens the address and token."
                        } else {
                            "Not set up"
                        },
                        icon = R.drawable.ic_connection,
                        onClick = onOpenGateway,
                    )
                }
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
        SettingDropdown(
            options = MicrophonePreference.entries,
            selected = selected,
            label = { it.displayName },
            detail = { if (it in status.available) it.detail else it.unavailableDetail },
            onSelect = onSelect,
            enabled = status.changeable,
            optionEnabled = { it in status.available || it == selected },
        )

        if (status.recording || status.route != null) {
            InfoRow("Input in use", status.inUseLabel(selected))
        }

        Text(
            if (!status.changeable) {
                "Finish the current dictation before changing microphones."
            } else {
                "Unavailable options have no matching mic. " +
                    "Android has the final say on routing."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * Always shown. Whisper can use the list. Other on-device engines cannot, so
 * the field disables and the warning stays visible instead of hiding the
 * section.
 */
@Composable
private fun CustomVocabularySection(
    vocabulary: String,
    onSave: (String) -> Unit,
    unsupportedModel: String?,
) {
    var draft by remember(vocabulary) { mutableStateOf(vocabulary) }
    val terms = remember(draft) { CustomVocabulary.terms(draft) }
    val whisperWarning = CustomVocabulary.whisperOnlyWarning(unsupportedModel)
    val whisperOnly = whisperWarning != null

    Section(
        title = "Custom words and phrases",
        supporting = "Names, places, and jargon an on-device Whisper model is " +
            "unlikely to know. One per line, or separated by commas.",
    ) {
        if (whisperWarning != null) {
            Notice(tone = NoticeTone.Warning) {
                Text(whisperWarning, style = MaterialTheme.typography.bodyMedium)
                Text(
                    "This list is kept for when you switch back to a Whisper model.",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            modifier = Modifier.fillMaxWidth(),
            enabled = !whisperOnly,
            label = { Text("Words and phrases") },
            placeholder = { Text("Kanishk\nVocaHQ\nTailscale") },
            minLines = 3,
            maxLines = 6,
        )
        if (!whisperOnly) {
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
        }
        SecondaryButton(
            text = "Save words",
            onClick = { onSave(draft) },
            enabled = !whisperOnly && draft != vocabulary,
        )
    }
}

@Composable
private fun TonePreviewMeter(active: Boolean, modifier: Modifier = Modifier) {
    val color = MaterialTheme.colorScheme.primary
    val muted = MaterialTheme.colorScheme.outlineVariant
    val wave by rememberInfiniteTransition(label = "tone-preview").animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(900, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "tone-preview-phase",
    )
    Canvas(
        modifier
            .fillMaxWidth()
            .height(48.dp),
    ) {
        val bars = 28
        val gap = 3.dp.toPx()
        val barWidth = ((size.width - gap * (bars - 1)) / bars).coerceAtLeast(1f)
        repeat(bars) { index ->
            val phase = (wave + index / bars.toFloat()) % 1f
            val heightFactor = if (active) {
                0.2f + 0.8f * abs(sin((phase * 2f + index * 0.35f) * Math.PI.toFloat()))
            } else {
                0.18f
            }
            val barHeight = size.height * heightFactor
            val x = index * (barWidth + gap)
            drawLine(
                color = if (active) color else muted,
                start = Offset(x + barWidth / 2f, (size.height - barHeight) / 2f),
                end = Offset(x + barWidth / 2f, (size.height + barHeight) / 2f),
                strokeWidth = barWidth,
            )
        }
    }
}


