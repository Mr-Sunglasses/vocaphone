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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.clickable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.InputChipDefaults
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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.vocahq.vocaphone.BuildConfig
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.core.DictationTone
import com.vocahq.vocaphone.core.MicrophonePreference
import com.vocahq.vocaphone.core.ModelTranslationSupport
import com.vocahq.vocaphone.core.Snippet
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.core.UsageStats
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.ime.PersonalDictionary
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelEngine
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.settings.AudioRetention
import com.vocahq.vocaphone.settings.BubbleBehavior
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
    FLOATING_MIC("Floating mic"),
    DICTATION("Dictation"),
    SNIPPETS("Snippets"),
    DICTIONARY("Personal dictionary"),
    CONNECTION("Speech"),
    STATS("Stats"),
    PRIVACY("Privacy"),
    HELP("Help and diagnostics"),
    ABOUT("About"),
    ;

    companion object {
        fun fromExtra(value: String?): SettingsPage = when (value?.lowercase()) {
            "models" -> MODELS
            "keyboard" -> if (BuildConfig.FLOATING_INPUT) FLOATING_MIC else KEYBOARD
            "floating_mic" -> FLOATING_MIC
            "dictation" -> DICTATION
            "snippets" -> SNIPPETS
            "dictionary" -> DICTIONARY
            "connection" -> CONNECTION
            "stats" -> STATS
            "privacy" -> PRIVACY
            "help" -> HELP
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
    historyCount: Int,
    onDeleteAllHistory: () -> Unit,
    installedApps: List<InstalledApp> = emptyList(),
    onLoadInstalledApps: () -> Unit = {},
    onAutomaticInsertion: (Boolean) -> Unit = {},
    onBubbleBehavior: (BubbleBehavior) -> Unit = {},
    onToggleExcludedApp: (String) -> Unit = {},
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
    // The list keeps its place while a sub-page is open, so Back returns to
    // the row that was tapped. Each sub-page starts at its top.
    val homeScrollState = rememberScrollState()
    val subPageScrollState = rememberScrollState()
    val pageScrollState = if (page == SettingsPage.HOME) homeScrollState else subPageScrollState

    // Each destination is its own page even though they share this container.
    // Carrying the Settings list position into Stats can open halfway through
    // the hero card, which makes the page look broken on first entry.
    LaunchedEffect(page) { if (page != SettingsPage.HOME) subPageScrollState.scrollTo(0) }

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
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(GroupSpacing),
    ) {
        when (page) {
            SettingsPage.HOME -> {
                SpeechSourceGroup(
                    settings = settings,
                    onOpenGateway = onOpenGateway,
                    onOpenModels = { onPageChange(SettingsPage.MODELS) },
                    onLocalTranscriptionEnabled = onLocalTranscriptionEnabled,
                )
                SettingsGroup(
                    title = if (BuildConfig.FLOATING_INPUT) "Dictation" else "Dictation and keyboard",
                ) {
                    SettingsNavRow(
                        title = "Language",
                        supporting = settings.effectiveLanguage.displayName,
                        icon = R.drawable.ic_language,
                        onClick = { pickingLanguage = true },
                    )
                    SettingsDivider(inset = true)
                    SettingsNavRow(
                        title = "Dictation",
                        supporting = settings.style.displayName,
                        icon = R.drawable.ic_dictation,
                        onClick = { onPageChange(SettingsPage.DICTATION) },
                    )
                    SettingsDivider(inset = true)
                    if (BuildConfig.FLOATING_INPUT) {
                        SettingsNavRow(
                            title = "Floating mic",
                            supporting = floatingMicSummary(setup),
                            icon = R.drawable.ic_dictation,
                            onClick = { onPageChange(SettingsPage.FLOATING_MIC) },
                        )
                    } else {
                        SettingsNavRow(
                            title = "Keyboard",
                            supporting = keyboardRowSummary(setup.ime),
                            icon = R.drawable.ic_keyboard,
                            onClick = { onPageChange(SettingsPage.KEYBOARD) },
                        )
                    }
                }
                SettingsGroup(title = "Your content") {
                    SettingsNavRow(
                        title = "Snippets",
                        supporting = countLabel(settings.snippets.size, "snippet"),
                        icon = R.drawable.ic_snippets,
                        onClick = { onPageChange(SettingsPage.SNIPPETS) },
                    )
                    SettingsDivider(inset = true)
                    SettingsNavRow(
                        title = "Personal dictionary",
                        supporting = countLabel(PersonalDictionary.terms(settings.personalDictionary).size, "word"),
                        icon = R.drawable.ic_dictionary,
                        onClick = { onPageChange(SettingsPage.DICTIONARY) },
                    )
                    SettingsDivider(inset = true)
                    SettingsNavRow(
                        title = "Stats",
                        supporting = StatsCopy.menuSupporting(usageStats, statsNow),
                        icon = R.drawable.ic_stats,
                        onClick = { onPageChange(SettingsPage.STATS) },
                    )
                }
                // The keyboard and this app both follow it, so it is not a
                // keyboard setting even though the keyboard is where it shows.
                SettingsGroup(title = "Appearance") {
                    SettingsSwitchRow(
                        title = "Use wallpaper colors",
                        supporting = "For the keyboard and this app.",
                        icon = R.drawable.ic_palette,
                        checked = settings.dynamicColorEnabled,
                        onCheckedChange = onDynamicColor,
                    )
                }
                SettingsGroup(title = "Privacy and help") {
                    SettingsNavRow(
                        title = "Privacy",
                        icon = R.drawable.ic_lock,
                        onClick = { onPageChange(SettingsPage.PRIVACY) },
                    )
                    SettingsDivider(inset = true)
                    SettingsNavRow(
                        title = "Help and diagnostics",
                        icon = R.drawable.ic_help,
                        onClick = { onPageChange(SettingsPage.HELP) },
                    )
                    SettingsDivider(inset = true)
                    SettingsNavRow(
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
                // Only where it changes anything: a Whisper model on this
                // phone. Sherpa models run one decoding mode, and a gateway
                // picks its own.
                if (settings.localTranscriptionEnabled && localModel?.engine == LocalModelEngine.WHISPER) {
                    SettingsGroup(
                        title = "Advanced",
                        footer = settings.transcriptionQuality.detail(localModel.engine),
                    ) {
                        SettingsChoiceRow(
                            title = "Accuracy",
                            options = TranscriptionQuality.entries,
                            selected = settings.transcriptionQuality,
                            label = { it.displayName },
                            detail = { it.detail(localModel.engine) },
                            onSelect = onTranscriptionQuality,
                        )
                    }
                }
            }

            SettingsPage.FLOATING_MIC -> {
                LaunchedEffect(Unit) { onLoadInstalledApps() }
                FloatingMicSettings(
                    settings = settings,
                    setup = setup,
                    installedApps = installedApps,
                    onAutomaticInsertion = onAutomaticInsertion,
                    onBubbleBehavior = onBubbleBehavior,
                    onToggleExcludedApp = onToggleExcludedApp,
                )
            }

            SettingsPage.KEYBOARD -> {
                if (SetupCopy.keyboardAction(setup.ime) != null) ImeSetupCard(setup.ime)
                SettingsGroup(
                    title = "Layout",
                    footer = "Split turns on by itself on wide screens, like an unfolded foldable.",
                ) {
                    SettingsSwitchRow(
                        title = "Number row",
                        supporting = "1 to 0 above the letters.",
                        checked = settings.numberRowEnabled,
                        onCheckedChange = onNumberRow,
                    )
                    SettingsDivider()
                    SettingsChoiceRow(
                        title = "Height",
                        options = KeyboardHeight.entries,
                        selected = settings.keyboardHeight,
                        label = { it.displayName },
                        onSelect = onKeyboardHeight,
                    )
                    SettingsDivider()
                    SettingsChoiceRow(
                        title = "Split keyboard",
                        options = SplitKeyboard.entries,
                        selected = settings.splitKeyboard,
                        label = { it.displayName },
                        onSelect = onSplitKeyboard,
                    )
                }
                SettingsGroup(title = "Typing", learnMore = SettingsHelp.typing) {
                    SettingsSwitchRow(
                        title = "Suggestions",
                        supporting = "Worked out on this phone. Off in passwords.",
                        checked = settings.suggestionsEnabled,
                        onCheckedChange = onSuggestions,
                    )
                    SettingsDivider()
                    SettingsSwitchRow(
                        title = "Corrections",
                        supporting = "Nearby words in the toolbar.",
                        checked = settings.correctionsEnabled,
                        onCheckedChange = onCorrections,
                    )
                    SettingsDivider()
                    SettingsSwitchRow(
                        title = "Swipe typing",
                        supporting = "Glide across letters. English only.",
                        checked = settings.swipeTypingEnabled,
                        onCheckedChange = onSwipeTyping,
                    )
                    SettingsDivider()
                    SettingsSwitchRow(
                        title = "Hold for digits and symbols",
                        supporting = "Slide for accents.",
                        checked = settings.longPressSymbolsEnabled,
                        onCheckedChange = onLongPressSymbols,
                    )
                    SettingsDivider()
                    SettingsSwitchRow(
                        title = "Number key hints",
                        supporting = "Show the symbol on 1 to 0.",
                        checked = settings.numberKeyHintsEnabled,
                        onCheckedChange = onNumberKeyHints,
                    )
                    SettingsDivider()
                    SettingsSwitchRow(
                        title = "Text emoticons",
                        supporting = "Adds :) and friends to the emoji panel.",
                        checked = settings.asciiEmojiEnabled,
                        onCheckedChange = onAsciiEmoji,
                    )
                }
                SettingsGroup(title = "Clipboard", learnMore = SettingsHelp.clipboard) {
                    SettingsSwitchRow(
                        title = "Clipboard chip",
                        supporting = "Paste the current clip in one tap.",
                        checked = settings.clipboardChipEnabled,
                        onCheckedChange = onClipboardChip,
                    )
                    SettingsDivider()
                    SettingsSwitchRow(
                        title = "Clipboard history",
                        supporting = "Kept on this phone. Off in passwords.",
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

            SettingsPage.DICTIONARY -> {
                PersonalDictionaryPage(
                    words = settings.personalDictionary,
                    onSave = onPersonalDictionary,
                    vocabulary = settings.customVocabulary,
                    synced = settings.syncWhisperDictionary,
                    onSyncedChange = onSyncWhisperDictionary,
                    onSaveVocabulary = onCustomVocabulary,
                    unsupportedModel = localModel
                        ?.takeIf { settings.localTranscriptionEnabled && !it.supportsCustomVocabulary }
                        ?.displayName,
                )
            }

            SettingsPage.DICTATION -> {
                val translationSupported =
                    ModelTranslationSupport.isSupported(settings.activeModelTranslationTargets)
                SettingsGroup(title = "Output", learnMore = SettingsHelp.output) {
                    SettingsChoiceRow(
                        title = "Writing style",
                        options = WritingStyle.entries,
                        selected = settings.style,
                        label = { it.displayName },
                        detail = { it.detail },
                        supporting = "${settings.style.displayName} · “${settings.style.example}”",
                        onSelect = onStyle,
                    )
                    SettingsDivider()
                    // Never hidden: "this model can't translate" is exactly the
                    // answer people come here for. It opens only when there is
                    // something to pick.
                    SettingsNavRow(
                        title = "Translate to",
                        supporting = ModelTranslationSupport.summary(
                            settings.translateTo,
                            settings.activeModelTranslationTargets,
                            onDevice = settings.localTranscriptionEnabled,
                            needsExplicitSource = localModel?.translationNeedsExplicitSource == true,
                            sourceIsAutomatic = settings.effectiveLanguage ==
                                TranscriptionLanguage.AUTOMATIC,
                        ),
                        onClick = { pickingTranslation = true }.takeIf { translationSupported },
                    )
                    SettingsDivider()
                    SettingsSwitchRow(
                        title = "Clean up speech",
                        supporting = "Drops “um”, “uh” and false starts.",
                        checked = settings.repairSpeech,
                        onCheckedChange = onRepairSpeech,
                    )
                    SettingsDivider()
                    SettingsSwitchRow(
                        title = "Write numbers as digits",
                        supporting = "“six pm” becomes “6 pm”. English only.",
                        checked = settings.numbersAsDigits,
                        onCheckedChange = onNumbersAsDigits,
                    )
                    SettingsDivider()
                    SettingsSwitchRow(
                        title = "Spoken emoji",
                        supporting = "“crying emoji” becomes 😭.",
                        checked = settings.spokenEmoji,
                        onCheckedChange = onSpokenEmoji,
                    )
                }
                SettingsGroup(
                    title = "Recording",
                    footer = microphoneFooter(settings.microphone, microphone),
                    learnMore = SettingsHelp.recording,
                ) {
                    SettingsChoiceRow(
                        title = "Start and stop sound",
                        options = DictationTone.entries,
                        selected = settings.dictationTone,
                        label = { it.displayName },
                        detail = { it.detail },
                        onSelect = onDictationTone,
                        trailing = if (settings.dictationTone.playsCues) {
                            {
                                TextButton(onClick = { onPreviewDictationTone(settings.dictationTone) }) {
                                    Text(if (tonePreviewListening) "Stop" else "Preview")
                                }
                            }
                        } else {
                            null
                        },
                    )
                    if (tonePreviewListening) {
                        SettingsGroupContent { TonePreviewMeter(active = true) }
                    }
                    SettingsDivider()
                    SettingsSwitchRow(
                        title = "Stop after a pause",
                        supporting = "Finishes after three seconds of quiet.",
                        checked = settings.stopAfterPause,
                        onCheckedChange = onStopAfterPause,
                    )
                    SettingsDivider()
                    SettingsChoiceRow(
                        title = "Microphone",
                        options = MicrophonePreference.entries,
                        selected = settings.microphone,
                        label = { it.displayName },
                        supporting = microphoneSummary(settings.microphone, microphone),
                        detail = { if (it in microphone.available) it.detail else it.unavailableDetail },
                        onSelect = onMicrophone,
                        enabled = microphone.changeable,
                        optionEnabled = { it in microphone.available || it == settings.microphone },
                    )
                    // Only a model on this phone is loaded into memory.
                    if (settings.localTranscriptionEnabled) {
                        SettingsDivider()
                        SettingsChoiceRow(
                            title = "Keep model loaded",
                            options = ModelIdleTimeout.entries,
                            selected = settings.modelIdleTimeout,
                            label = { it.displayName },
                            detail = { it.detail },
                            onSelect = onModelIdleTimeout,
                        )
                    }
                }
            }

            SettingsPage.PRIVACY -> {
                PrivacyPage(
                    audioRetention = settings.audioRetention,
                    onAudioRetention = onAudioRetention,
                    historyCount = historyCount,
                    onDeleteAllHistory = onDeleteAllHistory,
                    telemetryEnabled = settings.telemetryEnabled,
                    onTelemetryEnabled = onTelemetryEnabled,
                    telemetryInspect = telemetryInspect,
                    telemetryPendingCount = telemetryPendingCount,
                    telemetryDeliveryStatus = telemetryDeliveryStatus,
                )
            }

            SettingsPage.CONNECTION -> {
                SpeechSourceGroup(
                    settings = settings,
                    onOpenGateway = onOpenGateway,
                    onOpenModels = { onPageChange(SettingsPage.MODELS) },
                    onLocalTranscriptionEnabled = onLocalTranscriptionEnabled,
                )
            }

            SettingsPage.STATS -> {
                StatsPage(
                    stats = usageStats,
                    nowMillis = statsNow,
                    onReset = onResetUsageStats,
                )
            }

            SettingsPage.HELP -> {
                HelpPage(
                    appInfo = appInfo,
                    settings = settings,
                    setup = setup,
                    localModel = localModel,
                    onDevice = onDevice,
                    diagnosticEvents = diagnosticEvents,
                    onClearDiagnosticEvents = onClearDiagnosticEvents,
                )
            }

            SettingsPage.ABOUT -> {
                AboutPage(appInfo = appInfo)
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
 * The dictation word list as the user wrote it, one entry per line or comma.
 *
 * Not [CustomVocabulary.terms]: that one trims each entry to the decoder's
 * limit, and saving its output back would permanently shorten a long phrase
 * whenever any other word was added or removed. The limit still applies
 * where the list is used.
 */
internal fun editableVocabulary(raw: String): List<String> {
    val seen = mutableSetOf<String>()
    return raw.split('\n', ',')
        .map { it.trim() }
        .filter { it.isNotEmpty() && seen.add(it.lowercase()) }
}

/** "3 snippets", "1 word", "None yet". */
internal fun countLabel(count: Int, noun: String): String = when (count) {
    0 -> "None yet"
    1 -> "1 $noun"
    else -> "$count ${noun}s"
}

/** One state, in words, rather than "Selected · Default · number row". */
internal fun keyboardRowSummary(ime: ImeSetupStatus): String = when {
    ime.selected -> "On"
    ime.enabled -> "Turned on, not selected"
    else -> "Not turned on"
}

/** The floating-mic row's second line: the state of its two permissions. */
internal fun floatingMicSummary(setup: SetupStatus): String = when {
    !setup.overlay -> "Needs display-over-other-apps"
    !setup.accessibility -> "Needs accessibility"
    else -> "On"
}

/**
 * The X build's input page: where the transcript goes, when the mic is
 * allowed to appear, and which apps it stays out of.
 */
@Composable
private fun FloatingMicSettings(
    settings: VocaPhoneSettings,
    setup: SetupStatus,
    installedApps: List<InstalledApp>,
    onAutomaticInsertion: (Boolean) -> Unit,
    onBubbleBehavior: (BubbleBehavior) -> Unit,
    onToggleExcludedApp: (String) -> Unit,
) {
    val context = LocalContext.current
    if (!setup.accessibility || !setup.overlay) {
        SettingsGroup(title = "Setup") {
            SettingsNavRow(
                title = "Finish floating mic setup",
                supporting = "The mic needs the accessibility service and display-over-other-apps.",
                icon = R.drawable.ic_warning,
                onClick = {
                    if (!setup.overlay) {
                        FloatingSetup.openOverlaySettings(context)
                    } else {
                        FloatingSetup.openAccessibilitySettings(context)
                    }
                },
            )
        }
    }
    SettingsGroup(
        title = "Insertion",
    ) {
        SettingsSwitchRow(
            title = "Insert automatically",
            supporting = "Write the transcript straight into the focused field. When off, it waits in History for you.",
            checked = settings.automaticInsertion,
            onCheckedChange = onAutomaticInsertion,
        )
    }
    SettingsGroup(
        title = "Floating mic",
        footer = "The mic never appears in password or payment fields, on system permission screens, or in the apps you exclude below.",
    ) {
        SettingsChoiceRow(
            title = "Show the mic",
            options = BubbleBehavior.entries,
            selected = settings.bubbleBehavior,
            label = { it.displayName },
            onSelect = onBubbleBehavior,
        )
    }
    SettingsGroup(
        title = "Excluded apps",
        footer = "${settings.excludedPackages.size} excluded. The mic stays hidden and reads nothing in these apps.",
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxWidth().heightIn(max = 320.dp),
        ) {
            items(installedApps, key = { it.packageName }) { app ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onToggleExcludedApp(app.packageName) }
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(
                        checked = app.packageName in settings.excludedPackages,
                        onCheckedChange = { onToggleExcludedApp(app.packageName) },
                    )
                    Text(app.label, style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

/** The microphone row's second line: the choice, and what is in use while it is. */
private fun microphoneSummary(selected: MicrophonePreference, status: MicrophoneStatus): String {
    val choice = if (selected in status.available) selected.displayName else selected.unavailableDetail
    return if (status.recording || status.route != null) {
        "$choice · ${status.inUseLabel(selected)}"
    } else {
        choice
    }
}

private fun microphoneFooter(selected: MicrophonePreference, status: MicrophoneStatus): String = when {
    !status.changeable -> "Finish the current dictation before changing microphones."
    selected == MicrophonePreference.AUTOMATIC -> "Android picks the microphone unless you choose one."
    else -> "Android has the final say on which microphone records."
}

/**
 * What the app keeps and what it sends, in one place: failed audio, history,
 * and usage reporting. They used to be split between Dictation and About, and
 * this is the question someone holds when they come looking for any of them.
 */
@Composable
private fun PrivacyPage(
    audioRetention: AudioRetention,
    onAudioRetention: (AudioRetention) -> Unit,
    historyCount: Int,
    onDeleteAllHistory: () -> Unit,
    telemetryEnabled: Boolean,
    onTelemetryEnabled: (Boolean) -> Unit,
    telemetryInspect: () -> TelemetryInspectPayload,
    telemetryPendingCount: () -> Int,
    telemetryDeliveryStatus: () -> String,
) {
    var confirmingDelete by remember { mutableStateOf(false) }
    SettingsGroup(
        title = "On this phone",
        footer = "Successful dictations delete their audio at once. A failed one keeps it so Retry works.",
        learnMore = SettingsHelp.kept,
    ) {
        SettingsChoiceRow(
            title = "Keep failed audio",
            options = AudioRetention.entries,
            selected = audioRetention,
            label = { it.displayName },
            onSelect = onAudioRetention,
        )
        SettingsDivider()
        SettingsActionRow(
            title = "Delete all history",
            supporting = countLabel(historyCount, "dictation"),
            destructive = true,
            enabled = historyCount > 0,
            onClick = { confirmingDelete = true },
        )
    }
    UsageReportingSection(
        enabled = telemetryEnabled,
        onEnabled = onTelemetryEnabled,
        inspect = telemetryInspect,
        pendingCount = telemetryPendingCount,
        deliveryStatus = telemetryDeliveryStatus,
    )
    SettingsGroup(title = "How your data moves") {
        SettingsGroupContent {
            Text(
                ABOUT_PRIVACY_NOTE,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
    if (confirmingDelete) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text("Delete all history?") },
            text = {
                Text("This removes every dictation from this phone. Usage totals are kept; reset them in Stats.")
            },
            confirmButton = {
                DestructiveTextButton(
                    text = "Delete all",
                    onClick = {
                        onDeleteAllHistory()
                        confirmingDelete = false
                    },
                )
            },
            dismissButton = {
                TextButton(onClick = { confirmingDelete = false }) { Text("Cancel") }
            },
        )
    }
}

/**
 * One list for both places a name gets spelled your way: the suggestion strip
 * and dictation. They used to be two editors on two pages, the Dictation one
 * pointing at the Keyboard one.
 */
@Composable
private fun PersonalDictionaryPage(
    words: String,
    onSave: (String) -> Unit,
    vocabulary: String,
    synced: Boolean,
    onSyncedChange: (Boolean) -> Unit,
    onSaveVocabulary: (String) -> Unit,
    unsupportedModel: String?,
) {
    var confirmClear by remember { mutableStateOf(false) }
    val terms = PersonalDictionary.terms(words)
    SettingsGroup(
        title = "Words",
        footer = "Names and jargon the keyboard should know. Letters only. Off in passwords.",
    ) {
        WordListEditor(
            words = terms,
            placeholder = "Add a word, like Kubernetes",
            validate = { candidate ->
                if (PersonalDictionary.isSavable(candidate)) null else "Letters only, at least 3."
            },
            onAdd = { added -> onSave(added.fold(words) { acc, word -> PersonalDictionary.add(acc, word) }) },
            onRemove = { removed ->
                onSave(terms.filterNot { it.equals(removed, ignoreCase = true) }.joinToString(", "))
            },
        )
        if (terms.isNotEmpty()) {
            SettingsDivider()
            SettingsActionRow(
                title = "Clear all",
                destructive = true,
                onClick = { confirmClear = true },
            )
        }
    }
    val dictationTerms = editableVocabulary(vocabulary)
    SettingsGroup(
        title = "Dictation",
        footer = CustomVocabulary.spellingOnlyNote(unsupportedModel),
        learnMore = SettingsHelp.customWords,
    ) {
        SettingsSwitchRow(
            title = "Use these words for dictation",
            supporting = "Spells them your way in transcripts.",
            checked = synced,
            onCheckedChange = onSyncedChange,
        )
        if (!synced) {
            SettingsDivider()
            WordListEditor(
                words = dictationTerms,
                placeholder = "Add a word or phrase",
                validate = { null },
                onAdd = { added -> onSaveVocabulary(editableVocabulary((dictationTerms + added).joinToString("\n")).joinToString("\n")) },
                onRemove = { removed ->
                    onSaveVocabulary(dictationTerms.filterNot { it == removed }.joinToString("\n"))
                },
            )
        }
    }
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear personal dictionary?") },
            text = {
                Text(
                    if (terms.size == 1) {
                        "This removes 1 word from this phone."
                    } else {
                        "This removes ${terms.size} words from this phone."
                    },
                )
            },
            confirmButton = {
                DestructiveTextButton(
                    text = "Clear",
                    onClick = {
                        confirmClear = false
                        onSave("")
                    },
                )
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) { Text("Cancel") }
            },
        )
    }
}

/**
 * Words as chips you can remove, and one field to add more. Commas add several
 * at once, so a pasted list still works.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WordListEditor(
    words: List<String>,
    placeholder: String,
    validate: (String) -> String?,
    onAdd: (List<String>) -> Unit,
    onRemove: (String) -> Unit,
) {
    var draft by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    fun submit() {
        val candidates = draft.split(',', '\n').map { it.trim() }.filter { it.isNotEmpty() }
        if (candidates.isEmpty()) return
        val firstError = candidates.firstNotNullOfOrNull(validate)
        if (firstError != null) {
            error = firstError
            return
        }
        onAdd(candidates)
        draft = ""
        error = null
    }
    SettingsGroupContent {
        OutlinedTextField(
            value = draft,
            onValueChange = {
                draft = it
                error = null
            },
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text(placeholder) },
            singleLine = true,
            isError = error != null,
            supportingText = error?.let { message -> { Text(message) } },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { submit() }),
            trailingIcon = {
                IconButton(onClick = { submit() }, enabled = draft.isNotBlank()) {
                    Icon(painterResource(R.drawable.ic_add), contentDescription = "Add")
                }
            },
        )
        if (words.isNotEmpty()) {
            FlowRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                words.forEach { word ->
                    InputChip(
                        selected = false,
                        onClick = { onRemove(word) },
                        label = { Text(word) },
                        trailingIcon = {
                            Icon(
                                painterResource(R.drawable.ic_cancel),
                                contentDescription = "Remove $word",
                                modifier = Modifier.size(InputChipDefaults.IconSize),
                            )
                        },
                    )
                }
            }
        }
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

    SettingsGroup(
        footer = if (snippets.isEmpty()) {
            "Say “my email” while dictating and VocaPhone types your address."
        } else {
            "Say a trigger while dictating and it is replaced by its text."
        },
    ) {
        if (snippets.isEmpty()) {
            // The snippets nearly everyone ends up making, one tap from
            // working, so the feature explains itself.
            SNIPPET_STARTERS.forEach { trigger ->
                SettingsActionRow(
                    title = "“$trigger”",
                    icon = R.drawable.ic_add,
                    onClick = { starting = trigger },
                )
                SettingsDivider(inset = true)
            }
        } else {
            snippets.forEach { snippet ->
                SnippetRow(
                    snippet = snippet,
                    onEdit = { editing = snippet },
                    onDelete = { pendingDelete = snippet },
                )
                SettingsDivider()
            }
        }
        SettingsActionRow(
            title = "Add snippet",
            icon = R.drawable.ic_add,
            onClick = { adding = true },
        )
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

private val SNIPPET_STARTERS = listOf("my email", "my address", "my phone number")

@Composable
private fun SnippetRow(
    snippet: Snippet,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        SettingsTapRow(
            title = snippet.trigger,
            supporting = snippet.expansion,
            onClick = onEdit,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onDelete, modifier = Modifier.padding(end = 4.dp)) {
            Icon(
                painterResource(R.drawable.ic_delete),
                contentDescription = "Delete ${snippet.trigger}",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
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
