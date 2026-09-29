package com.vocahq.vocaphone.ui

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.ime.PersonalDictionary
import com.vocahq.vocaphone.core.DictationTone
import com.vocahq.vocaphone.core.MicrophonePreference
import com.vocahq.vocaphone.core.ModelTranslationSupport
import com.vocahq.vocaphone.core.Snippet
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelEngine
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.core.UsageStats
import com.vocahq.vocaphone.settings.AudioRetention
import com.vocahq.vocaphone.settings.KeyboardHeight
import com.vocahq.vocaphone.settings.ModelIdleTimeout
import com.vocahq.vocaphone.settings.SplitKeyboard
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import com.vocahq.vocaphone.telemetry.TelemetryInspectPayload
import kotlin.math.abs
import kotlin.math.sin
import kotlinx.coroutines.delay

enum class SettingsPage(val title: String) {
    HOME("Settings"),
    MODELS("Voice model"),
    KEYBOARD("Keyboard"),
    DICTATION("Dictation"),
    SNIPPETS("Snippets"),
    CONNECTION("Speech"),
    STATS("Stats"),
    ABOUT("About"),
    ;

    companion object {
        fun fromExtra(value: String?): SettingsPage = when (value?.lowercase()) {
            "models" -> MODELS
            "keyboard" -> KEYBOARD
            "dictation" -> DICTATION
            "snippets" -> SNIPPETS
            "connection" -> CONNECTION
            "stats" -> STATS
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
    onTranslateTo: (TranscriptionLanguage) -> Unit,
    onStyle: (WritingStyle) -> Unit,
    onRepairSpeech: (Boolean) -> Unit,
    onNumbersAsDigits: (Boolean) -> Unit,
    onSpokenEmoji: (Boolean) -> Unit,
    onDictationTone: (DictationTone) -> Unit,
    onStopAfterPause: (Boolean) -> Unit,
    onPreviewDictationTone: (DictationTone) -> Unit,
    tonePreviewListening: Boolean,
    onMicrophone: (MicrophonePreference) -> Unit,
    onAudioRetention: (AudioRetention) -> Unit,
    onModelIdleTimeout: (ModelIdleTimeout) -> Unit,
    onTranscriptionQuality: (TranscriptionQuality) -> Unit,
    onCustomVocabulary: (String) -> Unit,
    onSyncWhisperDictionary: (Boolean) -> Unit,
    onNumberRow: (Boolean) -> Unit,
    onKeyboardHeight: (KeyboardHeight) -> Unit,
    onSplitKeyboard: (SplitKeyboard) -> Unit,
    onDynamicColor: (Boolean) -> Unit,
    onSuggestions: (Boolean) -> Unit,
    onCorrections: (Boolean) -> Unit,
    onNumberKeyHints: (Boolean) -> Unit,
    onLongPressSymbols: (Boolean) -> Unit,
    onPersonalDictionary: (String) -> Unit,
    onAddSnippet: (trigger: String, expansion: String) -> Unit,
    onUpdateSnippet: (id: String, trigger: String, expansion: String) -> Unit,
    onDeleteSnippet: (id: String) -> Unit,
    onAsciiEmoji: (Boolean) -> Unit,
    onSwipeTyping: (Boolean) -> Unit,
    onClipboardChip: (Boolean) -> Unit,
    onClipboardHistory: (Boolean) -> Unit,
    localModels: LocalModelState,
    deviceLanguages: List<String> = emptyList(),
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
    usageStats: UsageStats,
    onResetUsageStats: () -> Unit,
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
    var pickingTranslation by remember { mutableStateOf(false) }
    val localModel = LocalModelCatalog.find(settings.localModelId)

    // A streak expires on a clock rather than on an interaction, so the reading
    // both streak displays share has to be refreshed by something other than the
    // user. Three things can age it, and each gets its own trigger below: the app
    // was away, the day turned, or the clock itself was redefined.
    val lifecycleOwner = LocalLifecycleOwner.current
    var clockTick by remember { mutableIntStateOf(0) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) clockTick++
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Not covered by the timer below: flying between zones moves the day
    // boundary without any time passing at all. The timer is not covered by this
    // either, since a quiet midnight broadcasts nothing.
    DisposableEffect(context) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                clockTick++
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_DATE_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
        }
        // Not exported: these are protected system broadcasts, and nothing on
        // the device has any business poking this screen's clock.
        context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        onDispose { context.unregisterReceiver(receiver) }
    }

    val statsNow = remember(usageStats, clockTick) { System.currentTimeMillis() }
    val pageScrollState = rememberScrollState()

    // Each destination is its own page even though they share this container.
    // Carrying the Settings list position into Stats can open halfway through
    // the hero card, which makes the page look broken on first entry.
    LaunchedEffect(page) { pageScrollState.scrollTo(0) }

    // Bumping the tick recomputes statsNow, which is this effect's own key, so
    // each firing schedules the next one.
    //
    // The resume observer above is not redundant with this: delay runs on the
    // main looper's uptime clock, which does not advance while the device is
    // asleep, so a phone that dozes past midnight is caught on the way back
    // rather than by this timer.
    LaunchedEffect(statsNow) {
        delay(UsageStats.millisUntilNextDay(statsNow))
        clockTick++
    }

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
            .wrapContentWidth(Alignment.CenterHorizontally)
            .widthIn(max = AppContentMaxWidth)
            .verticalScroll(pageScrollState)
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
                SettingsLabeledGroup("Dictation and keyboard") {
                    SettingsMenuRow(
                        title = "Language",
                        supporting = settings.effectiveLanguage.displayName,
                        icon = R.drawable.ic_language,
                        onClick = { pickingLanguage = true },
                    )
                    SettingsMenuDivider()
                    // Kept next to Language and never hidden. A row that
                    // disappears for most models would leave the question
                    // unanswered, and "not supported by this model" is exactly
                    // the answer people arrive looking for. It opens only when
                    // there is something to pick: a sheet with every language
                    // greyed out was a dead end.
                    SettingsMenuRow(
                        title = "Translate to",
                        supporting = ModelTranslationSupport.summary(
                            settings.translateTo,
                            settings.activeModelTranslationTargets,
                            onDevice = settings.localTranscriptionEnabled,
                            needsExplicitSource = localModel?.translationNeedsExplicitSource == true,
                            sourceIsAutomatic = settings.effectiveLanguage ==
                                TranscriptionLanguage.AUTOMATIC,
                        ),
                        icon = R.drawable.ic_language,
                        onClick = { pickingTranslation = true }
                            .takeIf { ModelTranslationSupport.isSupported(settings.activeModelTranslationTargets) },
                    )
                    SettingsMenuDivider()
                    SettingsMenuRow(
                        title = "Voice model",
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
                }
                // Grouped by what someone came to do: set up how they dictate,
                // look after what they have made, or find out about the app.
                SettingsLabeledGroup("Your content") {
                    SettingsMenuRow(
                        title = "Snippets",
                        supporting = when (val count = settings.snippets.size) {
                            0 -> "Expand a short phrase into longer text"
                            1 -> "1 snippet"
                            else -> "$count snippets"
                        },
                        icon = R.drawable.ic_snippets,
                        onClick = { onPageChange(SettingsPage.SNIPPETS) },
                    )
                    SettingsMenuDivider()
                    SettingsMenuRow(
                        title = "Stats",
                        supporting = StatsCopy.menuSupporting(usageStats, statsNow),
                        icon = R.drawable.ic_stats,
                        onClick = { onPageChange(SettingsPage.STATS) },
                    )
                }
                SettingsLabeledGroup("About") {
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
                    supporting = "${
                        settings.transcriptionQuality.detail(
                            localModel?.engine ?: LocalModelEngine.WHISPER,
                        )
                    }\n" +
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
                    selectionFromRetiredModel = settings.selectionIsRetiredModelReplacement,
                    usingGateway = !settings.localTranscriptionEnabled,
                    onSelect = onLocalModel,
                    onDownload = onDownloadLocalModel,
                    onDownloadAndUse = onDownloadAndUseLocalModel,
                    onCancelDownload = onCancelLocalModelDownload,
                    onDelete = onDeleteLocalModel,
                    guidanceLanguage = settings.language.wireValue,
                    languages = deviceLanguages,
                    onGuidanceLanguage = { onLanguage(TranscriptionLanguage.fromWire(it)) },
                )
            }

            SettingsPage.KEYBOARD -> {
                ImeSetupCard(setup.ime)
                Section("Appearance") {
                    SettingToggle(
                        title = "Dynamic color",
                        detail = "Follow the wallpaper colors.",
                        checked = settings.dynamicColorEnabled,
                        onCheckedChange = onDynamicColor,
                    )
                }
                Section("Layout", learnMore = SettingsHelp.keyboardLayout) {
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
                }
                Section("Typing", learnMore = SettingsHelp.typing) {
                    SettingToggle(
                        title = "Suggestions",
                        detail = "Worked out on this phone. Off in passwords.",
                        checked = settings.suggestionsEnabled,
                        onCheckedChange = onSuggestions,
                    )
                    SettingToggle(
                        title = "Corrections",
                        detail = "Nearby words in the toolbar.",
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
                        title = "Hold for digits and symbols",
                        detail = "Hold a letter for its symbol. Slide for accents.",
                        checked = settings.longPressSymbolsEnabled,
                        onCheckedChange = onLongPressSymbols,
                    )
                    SettingToggle(
                        title = "Text emoticons",
                        detail = "Adds :) and friends to the emoji panel.",
                        checked = settings.asciiEmojiEnabled,
                        onCheckedChange = onAsciiEmoji,
                    )
                    SettingToggle(
                        title = "Swipe typing",
                        detail = "Glide across letters. English only.",
                        checked = settings.swipeTypingEnabled,
                        onCheckedChange = onSwipeTyping,
                    )
                }
                PersonalDictionarySection(
                    words = settings.personalDictionary,
                    onSave = onPersonalDictionary,
                )
                Section("Clipboard", learnMore = SettingsHelp.clipboard) {
                    SettingToggle(
                        title = "Clipboard chip",
                        detail = "Paste the current clip in one tap.",
                        checked = settings.clipboardChipEnabled,
                        onCheckedChange = onClipboardChip,
                    )
                    SettingToggle(
                        title = "Clipboard history",
                        detail = "Recent clips, kept on this phone. Off in passwords.",
                        checked = settings.clipboardHistoryEnabled,
                        onCheckedChange = onClipboardHistory,
                    )
                }
            }

            SettingsPage.SNIPPETS -> {
                SnippetsSection(
                    snippets = settings.snippets,
                    onAdd = onAddSnippet,
                    onUpdate = onUpdateSnippet,
                    onDelete = onDeleteSnippet,
                )
            }

            SettingsPage.DICTATION -> {
                // How your words come out, how recording behaves, what is
                // kept, and which words to spell your way — instead of eleven
                // sections. One line per control; the rules are behind each ⓘ.
                Section(title = "Output", learnMore = SettingsHelp.output) {
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
                    SettingToggle(
                        title = "Clean up speech",
                        detail = "Drops \u201Cum\u201D, \u201Cuh\u201D and false starts.",
                        checked = settings.repairSpeech,
                        onCheckedChange = onRepairSpeech,
                    )
                    SettingToggle(
                        title = "Write numbers as digits",
                        detail = "\u201Csix pm\u201D becomes \u201C6 pm\u201D. English only.",
                        checked = settings.numbersAsDigits,
                        onCheckedChange = onNumbersAsDigits,
                    )
                    SettingToggle(
                        title = "Spoken emoji",
                        detail = "\u201Ccrying emoji\u201D becomes 😭.",
                        checked = settings.spokenEmoji,
                        onCheckedChange = onSpokenEmoji,
                    )
                }
                Section(title = "Recording", learnMore = SettingsHelp.recording) {
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
                        text = if (tonePreviewListening) "Stop preview" else "Preview tone",
                        onClick = { onPreviewDictationTone(settings.dictationTone) },
                        enabled = settings.dictationTone.playsCues,
                    )
                    SettingToggle(
                        title = "Stop after a pause",
                        detail = "Finishes after three seconds of quiet.",
                        checked = settings.stopAfterPause,
                        onCheckedChange = onStopAfterPause,
                    )
                    Text("Keep model loaded", style = MaterialTheme.typography.bodyMedium)
                    SettingDropdown(
                        options = ModelIdleTimeout.entries,
                        selected = settings.modelIdleTimeout,
                        label = { it.displayName },
                        detail = { it.detail },
                        onSelect = onModelIdleTimeout,
                    )
                }
                MicrophoneSection(
                    selected = settings.microphone,
                    status = microphone,
                    onSelect = onMicrophone,
                )
                Section(
                    title = "Keep failed audio",
                    supporting = "So Retry still works. Successful dictations delete it at once.",
                    learnMore = SettingsHelp.kept,
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
                    inspect = telemetryInspect,
                    pendingCount = telemetryPendingCount,
                    deliveryStatus = telemetryDeliveryStatus,
                )
                CustomVocabularySection(
                    vocabulary = settings.customVocabulary,
                    personalDictionary = settings.personalDictionary,
                    synced = settings.syncWhisperDictionary,
                    onSyncedChange = onSyncWhisperDictionary,
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
                        title = "Voice model",
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

            SettingsPage.STATS -> {
                StatsPage(
                    stats = usageStats,
                    nowMillis = statsNow,
                    onReset = onResetUsageStats,
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
            translationTargets = settings.activeModelTranslationTargets,
            onSelect = onLanguage,
            onDismiss = { pickingLanguage = false },
        )
    }

    if (pickingTranslation) {
        LanguagePickerSheet(
            selected = settings.effectiveTranslateTo,
            modelLanguages = settings.activeModelLanguages,
            detectsLanguageAutomatically = settings.activeModelDetectsLanguage,
            onDevice = settings.localTranscriptionEnabled,
            mode = LanguagePickerMode.TRANSLATION,
            translationTargets = settings.activeModelTranslationTargets,
            translationNeedsSource = settings.activeModelTranslationNeedsSource,
            sourceIsAutomatic = settings.effectiveLanguage == TranscriptionLanguage.AUTOMATIC,
            onSelect = onTranslateTo,
            onDismiss = { pickingTranslation = false },
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

@Composable
private fun PersonalDictionarySection(
    words: String,
    onSave: (String) -> Unit,
) {
    var draft by remember(words) { mutableStateOf(PersonalDictionary.normalize(words)) }
    var lastCleared by remember { mutableStateOf<String?>(null) }
    var confirmClear by remember { mutableStateOf(false) }
    val terms = remember(draft) { PersonalDictionary.terms(draft) }
    val canUndo = lastCleared != null && words.isBlank()
    val canClear = words.isNotBlank()
    Section(
        title = "Personal dictionary",
        supporting = "Names and jargon the English list misses. " +
            "Separate with commas. Off in passwords. " +
            "Whisper uses this list too unless you turn that off under Dictation.",
    ) {
        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text("Grafana, GraphQL, Kubernetes, Docker") },
            minLines = 3,
            maxLines = 8,
        )
        Text(
            when (terms.size) {
                0 -> "None saved."
                1 -> "1 word."
                else -> "${terms.size} words."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        val saveWords: @Composable (Modifier) -> Unit = { item ->
            SecondaryButton(
                text = "Save words",
                onClick = {
                    lastCleared = null
                    onSave(draft)
                },
                enabled = PersonalDictionary.normalize(draft) != PersonalDictionary.normalize(words),
                modifier = item,
            )
        }
        when {
            canUndo -> ResponsiveActionRow(
                leading = saveWords,
                trailing = { item ->
                    SecondaryButton(
                        text = "Undo",
                        onClick = {
                            val restored = lastCleared ?: return@SecondaryButton
                            lastCleared = null
                            draft = restored
                            onSave(restored)
                        },
                        modifier = item,
                    )
                },
            )
            canClear -> ResponsiveActionRow(
                leading = saveWords,
                trailing = { item ->
                    DestructiveTextButton(
                        text = "Clear",
                        onClick = { confirmClear = true },
                        modifier = item,
                    )
                },
            )
            else -> saveWords(Modifier.fillMaxWidth())
        }
    }
    if (confirmClear) {
        val count = PersonalDictionary.terms(words).size
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear personal dictionary?") },
            text = {
                Text(
                    if (count == 1) {
                        "This removes 1 word from this phone."
                    } else {
                        "This removes $count words from this phone."
                    },
                )
            },
            confirmButton = {
                DestructiveTextButton(
                    text = "Clear",
                    onClick = {
                        lastCleared = words
                        confirmClear = false
                        draft = ""
                        onSave("")
                    },
                )
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) {
                    Text("Cancel")
                }
            },
        )
    }
}

/**
 * Trigger phrases dictated text is expanded against once a dictation
 * finishes, after the writing style has already run.
 *
 * Its own page rather than a section under Keyboard: it rewrites what
 * dictation types, has nothing to do with the key layout, and nobody scrolls
 * to the bottom of another page to discover a feature they don't know exists.
 */
@Composable
private fun SnippetsSection(
    snippets: List<Snippet>,
    onAdd: (trigger: String, expansion: String) -> Unit,
    onUpdate: (id: String, trigger: String, expansion: String) -> Unit,
    onDelete: (id: String) -> Unit,
) {
    var adding by remember { mutableStateOf(false) }
    var starting by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf<Snippet?>(null) }
    var pendingDelete by remember { mutableStateOf<Snippet?>(null) }

    Section(
        title = "Your snippets",
        supporting = if (snippets.isEmpty()) {
            "Say \u201Cmy email\u201D while dictating and VocaPhone types your address."
        } else {
            "Say a trigger while dictating and it is replaced by its text. Case does not matter."
        },
    ) {
        if (snippets.isEmpty()) {
            // The snippets nearly everyone ends up making, one tap from
            // working, so the feature explains itself.
            SNIPPET_STARTERS.forEach { trigger ->
                TextButton(onClick = { starting = trigger }) { Text("+ \u201C$trigger\u201D") }
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                snippets.forEach { snippet ->
                    SnippetRow(
                        snippet = snippet,
                        onEdit = { editing = snippet },
                        onDelete = { pendingDelete = snippet },
                    )
                }
            }
        }
        SecondaryButton(text = "Add snippet", onClick = { adding = true })
    }

    starting?.let { trigger ->
        SnippetEditorDialog(
            title = "Add snippet",
            initialTrigger = trigger,
            initialExpansion = "",
            onDismiss = { starting = null },
            onSave = { savedTrigger, expansion ->
                onAdd(savedTrigger, expansion)
                starting = null
            },
        )
    }

    if (adding) {
        SnippetEditorDialog(
            title = "Add snippet",
            initialTrigger = "",
            initialExpansion = "",
            onDismiss = { adding = false },
            onSave = { trigger, expansion ->
                onAdd(trigger, expansion)
                adding = false
            },
        )
    }

    editing?.let { snippet ->
        SnippetEditorDialog(
            title = "Edit snippet",
            initialTrigger = snippet.trigger,
            initialExpansion = snippet.expansion,
            onDismiss = { editing = null },
            onSave = { trigger, expansion ->
                onUpdate(snippet.id, trigger, expansion)
                editing = null
            },
        )
    }

    pendingDelete?.let { snippet ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete snippet?") },
            text = { Text("\"${snippet.trigger}\" will no longer expand.") },
            confirmButton = {
                DestructiveTextButton(
                    text = "Delete",
                    onClick = {
                        onDelete(snippet.id)
                        pendingDelete = null
                    },
                )
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
        )
    }
}

/** A group of Settings rows under a small heading. */
@Composable
private fun SettingsLabeledGroup(label: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            label,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(start = 4.dp),
        )
        SettingsMenuGroup { content() }
    }
}

private val SNIPPET_STARTERS = listOf("my email", "my address", "my phone number")

@Composable
private fun SnippetRow(
    snippet: Snippet,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onEdit)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(snippet.trigger, style = MaterialTheme.typography.titleSmall)
            Text(
                snippet.expansion,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
            )
        }
        DestructiveTextButton(text = "Delete", onClick = onDelete)
    }
}

@Composable
private fun SnippetEditorDialog(
    title: String,
    initialTrigger: String,
    initialExpansion: String,
    onDismiss: () -> Unit,
    onSave: (trigger: String, expansion: String) -> Unit,
) {
    var trigger by remember { mutableStateOf(initialTrigger) }
    var expansion by remember { mutableStateOf(initialExpansion) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = trigger,
                    onValueChange = { trigger = it },
                    label = { Text("Trigger") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = expansion,
                    onValueChange = { expansion = it },
                    label = { Text("Expansion") },
                    minLines = 2,
                    maxLines = 6,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSave(trigger, expansion) },
                // The trigger is trimmed before saving; the expansion is not,
                // since leading or trailing whitespace can be intentional. Both
                // are still required non-blank, or a snippet could silently
                // delete its trigger word from every future dictation.
                enabled = trigger.isNotBlank() && expansion.isNotBlank(),
            ) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

/**
 * Always shown and always editable. Every route spells close matches the
 * user's way; only Whisper is also nudged toward the words while decoding, and
 * a note says so for any other model.
 */
@Composable
private fun CustomVocabularySection(
    vocabulary: String,
    personalDictionary: String,
    synced: Boolean,
    onSyncedChange: (Boolean) -> Unit,
    onSave: (String) -> Unit,
    unsupportedModel: String?,
) {
    var draft by remember(vocabulary) { mutableStateOf(vocabulary) }
    val source = if (synced) personalDictionary else draft
    val terms = remember(source) { CustomVocabulary.terms(source) }
    val spellingOnly = CustomVocabulary.spellingOnlyNote(unsupportedModel)

    Section(
        title = "Custom words and phrases",
        supporting = "Names and jargon to spell your way, one per line.",
        learnMore = SettingsHelp.customWords,
    ) {
        // Switch, not a checkbox: Material 3 uses switches for independent
        // on/off settings. A checkbox is for picking items from a list.
        SettingToggle(
            title = "Use personal dictionary",
            detail = "Dictation uses the same names as the suggestion strip. " +
                "Turn this off to keep a separate list.",
            checked = synced,
            onCheckedChange = onSyncedChange,
        )
        if (spellingOnly != null) {
            Text(
                spellingOnly,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (synced) {
            Text(
                when (terms.size) {
                    0 -> "No words in the personal dictionary. Transcription is unchanged."
                    1 -> "1 word from the personal dictionary will be spelled your way."
                    else -> "${terms.size} words from the personal dictionary will be spelled your way."
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                "Edit them under Keyboard → Personal dictionary.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
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
                    "${terms.size} word${if (terms.size == 1) "" else "s"} will be spelled your way."
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            SecondaryButton(
                text = "Save words",
                onClick = { onSave(draft) },
                enabled = draft != vocabulary,
            )
        }
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
