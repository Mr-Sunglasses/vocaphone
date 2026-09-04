package com.vocahq.vocaphone.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.ui.theme.VocaPhoneTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filter

class MainActivity : ComponentActivity() {
    private val launchIntents = MutableStateFlow<Intent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        launchIntents.value = intent
        enableEdgeToEdge()
        setContent {
            val launchIntent by launchIntents.collectAsStateWithLifecycle()
            VocaPhoneTheme {
                VocaPhoneApp(launchIntent = launchIntent)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        launchIntents.value = intent
    }

    companion object {
        const val EXTRA_OPEN_SETTINGS = "open_settings"
        const val EXTRA_OPEN_MODELS = "open_models"
        const val EXTRA_SETTINGS_PAGE = "settings_page"
    }
}

private enum class Destination(val label: String, @param:DrawableRes val icon: Int) {
    DICTATE("Dictate", R.drawable.ic_dictation),
    HISTORY("History", R.drawable.ic_history),
    SETTINGS("Settings", R.drawable.ic_settings),
}

/** Main destinations share the mark. Nested pages keep a plain title. */
@Composable
private fun BrandedAppBarTitle(text: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            painter = painterResource(SetupCopy.LOGO),
            contentDescription = null,
            modifier = Modifier.size(24.dp),
            tint = Color.Unspecified,
        )
        Text(text)
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun VocaPhoneApp(
    viewModel: VocaPhoneViewModel = viewModel(),
    launchIntent: android.content.Intent? = null,
) {
    val settings by viewModel.settings.collectAsStateWithLifecycle()
    val setup by viewModel.setup.collectAsStateWithLifecycle()
    val dictation by viewModel.dictation.collectAsStateWithLifecycle()
    val history by viewModel.history.collectAsStateWithLifecycle()
    val connection by viewModel.connection.collectAsStateWithLifecycle()
    val testing by viewModel.testing.collectAsStateWithLifecycle()
    val microphone by viewModel.microphone.collectAsStateWithLifecycle()
    val localModels by viewModel.localModels.collectAsStateWithLifecycle()
    val tonePreviewListening by viewModel.tonePreviewListening.collectAsStateWithLifecycle()

    // The selected keyboard is a system setting, so its state can change while
    // the app is in the background; re-read setup on every resume.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) viewModel.refreshSetup()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // The keyboard picker is a system dialog: it takes the window's focus
    // without taking the activity out of the resumed state, so choosing a
    // keyboard there produces no lifecycle event to read on. Getting focus back
    // is the event it does produce. VocaPhoneViewModel watches the settings
    // themselves, which is the mechanism that should carry this; this is here
    // because a ROM is allowed to refuse that observer, and a stuck checklist
    // is not a good way to find out.
    val windowInfo = LocalWindowInfo.current
    LaunchedEffect(windowInfo) {
        snapshotFlow { windowInfo.isWindowFocused }
            .filter { it }
            .collect { viewModel.refreshSetup() }
    }

    var destination by remember { mutableStateOf(Destination.DICTATE) }
    var settingsPage by remember { mutableStateOf(SettingsPage.HOME) }
    var showingGateway by remember { mutableStateOf(false) }
    var openLanguagePicker by remember { mutableStateOf(false) }
    var historySelection by remember { mutableStateOf(emptySet<String>()) }
    var historySelecting by remember { mutableStateOf(false) }
    var confirmDeleteHistory by remember { mutableStateOf(false) }
    val selectingHistory = destination == Destination.HISTORY && historySelecting
    fun exitHistorySelection() {
        historySelecting = false
        historySelection = emptySet()
        confirmDeleteHistory = false
    }

    LaunchedEffect(launchIntent) {
        val incoming = launchIntent ?: return@LaunchedEffect
        if (!incoming.getBooleanExtra(MainActivity.EXTRA_OPEN_SETTINGS, false)) return@LaunchedEffect
        destination = Destination.SETTINGS
        settingsPage = SettingsPage.fromExtra(
            incoming.getStringExtra(MainActivity.EXTRA_SETTINGS_PAGE)
                ?: incoming.takeIf { it.getBooleanExtra(MainActivity.EXTRA_OPEN_MODELS, false) }
                    ?.let { "models" },
        )
    }

    val showSetup = !settings.onboardingComplete && !showingGateway
    val imeVisible = WindowInsets.isImeVisible

    Scaffold(
        contentWindowInsets = WindowInsets.safeDrawing,
        topBar = {
            TopAppBar(
                colors = if (selectingHistory) {
                    TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.primaryContainer,
                        navigationIconContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                        titleContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                        actionIconContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                } else {
                    TopAppBarDefaults.topAppBarColors()
                },
                title = {
                    if (selectingHistory) {
                        Text(historySelectionTitle(historySelection.size))
                    } else {
                        val titleText = when {
                            showingGateway -> "Gateway"
                            showSetup -> "Setup"
                            destination == Destination.DICTATE -> "VocaPhone"
                            destination == Destination.SETTINGS -> settingsPage.title
                            else -> destination.label
                        }
                        val branded = when {
                            showingGateway -> false
                            showSetup -> true
                            destination != Destination.SETTINGS -> true
                            else -> settingsPage == SettingsPage.HOME
                        }
                        if (branded) {
                            BrandedAppBarTitle(titleText)
                        } else {
                            Text(titleText)
                        }
                    }
                },
                navigationIcon = {
                    when {
                        selectingHistory -> {
                            IconButton(onClick = { exitHistorySelection() }) {
                                Icon(
                                    painterResource(R.drawable.ic_cancel),
                                    contentDescription = "Close",
                                )
                            }
                        }
                        showingGateway -> {
                            IconButton(onClick = { showingGateway = false }) {
                                Icon(
                                    painterResource(R.drawable.ic_back),
                                    contentDescription = "Back",
                                )
                            }
                        }
                        destination == Destination.SETTINGS && settingsPage != SettingsPage.HOME -> {
                            IconButton(onClick = { settingsPage = SettingsPage.HOME }) {
                                Icon(
                                    painterResource(R.drawable.ic_back),
                                    contentDescription = "Back",
                                )
                            }
                        }
                    }
                },
                actions = {
                    if (selectingHistory) {
                        val allSelected = history.isNotEmpty() &&
                            historySelection.size == history.size
                        TextButton(
                            onClick = {
                                historySelection = if (allSelected) {
                                    emptySet()
                                } else {
                                    history.map { it.sessionId }.toSet()
                                }
                            },
                            colors = ButtonDefaults.textButtonColors(
                                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                            ),
                        ) {
                            Text(if (allSelected) "Clear" else "Select all")
                        }
                        if (historySelection.isNotEmpty()) {
                            IconButton(onClick = { confirmDeleteHistory = true }) {
                                Icon(
                                    painter = painterResource(R.drawable.ic_delete),
                                    contentDescription = "Delete",
                                    tint = MaterialTheme.colorScheme.error,
                                )
                            }
                        }
                    } else if (
                        !showSetup &&
                        !showingGateway &&
                        destination == Destination.HISTORY &&
                        history.isNotEmpty()
                    ) {
                        TextButton(onClick = { historySelecting = true }) {
                            Text("Select")
                        }
                    }
                },
            )
        },
        bottomBar = {
            if (!showSetup && !showingGateway && !imeVisible) {
                NavigationBar {
                    Destination.entries.forEach { entry ->
                        NavigationBarItem(
                            selected = destination == entry,
                            onClick = {
                                if (destination == Destination.SETTINGS && entry == Destination.SETTINGS) {
                                    settingsPage = SettingsPage.HOME
                                }
                                if (entry != Destination.HISTORY) exitHistorySelection()
                                destination = entry
                            },
                            icon = { Icon(painterResource(entry.icon), contentDescription = entry.label) },
                            label = { Text(entry.label) },
                        )
                    }
                }
            }
        },
    ) { padding ->
        val content = Modifier.padding(padding)
        when {
            showingGateway -> GatewayScreen(
                settings = settings,
                connection = connection,
                testing = testing,
                inOnboarding = !settings.onboardingComplete,
                onSave = viewModel::saveGateway,
                onTest = viewModel::testConnection,
                onClear = {
                    viewModel.clearGateway()
                    showingGateway = false
                },
                onDone = { showingGateway = false },
                modifier = content,
            )

            showSetup -> SetupScreen(
                status = setup,
                settings = settings,
                localModels = localModels,
                onOpenGateway = { showingGateway = true },
                onLanguage = viewModel::setLanguage,
                onLocalTranscriptionEnabled = viewModel::setLocalTranscriptionEnabled,
                onLocalModel = viewModel::setLocalModel,
                onDownloadLocalModel = viewModel::downloadLocalModel,
                onDownloadAndUseLocalModel = viewModel::downloadAndUseLocalModel,
                onCancelLocalModelDownload = viewModel::cancelLocalModelDownload,
                onTelemetryDecision = { enabled ->
                    // The answer and the fact of having asked are recorded
                    // separately: "declined" and "not asked yet" have to stay
                    // distinguishable, or a no becomes a question repeated on
                    // every trip through guided setup.
                    viewModel.setTelemetryEnabled(enabled)
                    viewModel.setTelemetryAsked()
                },
                telemetryInspect = viewModel::telemetryInspect,
                telemetryPendingCount = viewModel::telemetryPendingCount,
                telemetryDeliveryStatus = viewModel::telemetryDeliveryStatus,
                onFinish = { viewModel.setOnboardingComplete(true) },
                onRefreshSetup = viewModel::refreshSetup,
                modifier = content,
            )

            destination == Destination.DICTATE -> DictateScreen(
                state = dictation,
                settings = settings,
                setup = setup,
                onStart = viewModel::startInAppDictation,
                onFinish = viewModel::finishDictation,
                onCancel = viewModel::cancelDictation,
                onRetry = viewModel::retry,
                onDismiss = viewModel::dismissDictation,
                onOpenGateway = { showingGateway = true },
                onRefreshSetup = viewModel::refreshSetup,
                onOpenLanguage = {
                    destination = Destination.SETTINGS
                    settingsPage = SettingsPage.HOME
                    openLanguagePicker = true
                },
                onOpenStyle = {
                    destination = Destination.SETTINGS
                    settingsPage = SettingsPage.DICTATION
                },
                onOpenModel = {
                    if (settings.localTranscriptionEnabled) {
                        destination = Destination.SETTINGS
                        settingsPage = SettingsPage.MODELS
                    } else {
                        showingGateway = true
                    }
                },
                onTelemetryDecision = { enabled ->
                    viewModel.setTelemetryEnabled(enabled)
                    viewModel.setTelemetryAsked()
                },
                telemetryInspect = viewModel::telemetryInspect,
                telemetryPendingCount = viewModel::telemetryPendingCount,
                telemetryDeliveryStatus = viewModel::telemetryDeliveryStatus,
                modifier = content,
            )

            destination == Destination.HISTORY -> HistoryScreen(
                records = history,
                selectedIds = historySelection,
                selecting = historySelecting,
                onRetry = viewModel::retry,
                onToggleSelect = { id ->
                    historySelection = toggleHistorySelection(historySelection, id)
                },
                onEnterSelect = { id ->
                    historySelecting = true
                    historySelection = setOf(id)
                },
                modifier = content,
            )

            else -> SettingsScreen(
                settings = settings,
                setup = setup,
                microphone = microphone,
                onLanguage = { viewModel.setLanguage(it) },
                onTranslateTo = { viewModel.setTranslateTo(it) },
                onStyle = { viewModel.setStyle(it) },
                onRepairSpeech = { viewModel.setRepairSpeech(it) },
                onNumbersAsDigits = { viewModel.setNumbersAsDigits(it) },
                onSpokenEmoji = { viewModel.setSpokenEmoji(it) },
                onDictationTone = { viewModel.setDictationTone(it) },
                onPreviewDictationTone = { viewModel.toggleDictationTonePreview(it) },
                tonePreviewListening = tonePreviewListening,
                onMicrophone = { viewModel.setMicrophone(it) },
                onAudioRetention = { viewModel.setAudioRetention(it) },
                onModelIdleTimeout = { viewModel.setModelIdleTimeout(it) },
                onTranscriptionQuality = { viewModel.setTranscriptionQuality(it) },
                onCustomVocabulary = { viewModel.setCustomVocabulary(it) },
                onSyncWhisperDictionary = { viewModel.setSyncWhisperDictionary(it) },
                onNumberRow = { viewModel.setNumberRowEnabled(it) },
                onKeyboardHeight = { viewModel.setKeyboardHeight(it) },
                onSplitKeyboard = { viewModel.setSplitKeyboard(it) },
                onSuggestions = { viewModel.setSuggestionsEnabled(it) },
                onCorrections = { viewModel.setCorrectionsEnabled(it) },
                onNumberKeyHints = { viewModel.setNumberKeyHintsEnabled(it) },
                onLongPressSymbols = { viewModel.setLongPressSymbolsEnabled(it) },
                onPersonalDictionary = { viewModel.setPersonalDictionary(it) },
                onAddSnippet = { trigger, expansion -> viewModel.addSnippet(trigger, expansion) },
                onUpdateSnippet = { id, trigger, expansion -> viewModel.updateSnippet(id, trigger, expansion) },
                onDeleteSnippet = { viewModel.deleteSnippet(it) },
                onAsciiEmoji = { viewModel.setAsciiEmojiEnabled(it) },
                onSwipeTyping = { viewModel.setSwipeTypingEnabled(it) },
                onClipboardChip = { viewModel.setClipboardChipEnabled(it) },
                onClipboardHistory = { viewModel.setClipboardHistoryEnabled(it) },
                localModels = localModels,
                onLocalTranscriptionEnabled = viewModel::setLocalTranscriptionEnabled,
                onLocalModel = viewModel::setLocalModel,
                onDownloadLocalModel = viewModel::downloadLocalModel,
                onDownloadAndUseLocalModel = viewModel::downloadAndUseLocalModel,
                onCancelLocalModelDownload = viewModel::cancelLocalModelDownload,
                onDeleteLocalModel = viewModel::deleteLocalModel,
                onOpenGateway = { showingGateway = true },
                diagnosticEvents = viewModel::diagnosticEvents,
                onClearDiagnosticEvents = viewModel::clearDiagnosticEvents,
                // Answering the switch in Settings counts as answering the
                // question, or the onboarding card keeps asking someone to opt
                // into something they already turned on.
                onTelemetryEnabled = { enabled ->
                    viewModel.setTelemetryEnabled(enabled)
                    viewModel.setTelemetryAsked()
                },
                telemetryInspect = viewModel::telemetryInspect,
                telemetryPendingCount = viewModel::telemetryPendingCount,
                telemetryDeliveryStatus = viewModel::telemetryDeliveryStatus,
                page = settingsPage,
                onPageChange = { settingsPage = it },
                openLanguagePicker = openLanguagePicker,
                onLanguagePickerOpened = { openLanguagePicker = false },
                modifier = content,
            )
        }
    }

    if (confirmDeleteHistory && historySelection.isNotEmpty()) {
        val count = historySelection.size
        val deletingAll = count == history.size
        AlertDialog(
            onDismissRequest = { confirmDeleteHistory = false },
            title = {
                Text(
                    when {
                        deletingAll -> "Delete all history?"
                        count == 1 -> "Delete this dictation?"
                        else -> "Delete $count dictations?"
                    },
                )
            },
            text = { Text("This removes them from this phone.") },
            confirmButton = {
                DestructiveTextButton(
                    text = if (deletingAll) "Delete all" else "Delete",
                    onClick = {
                        if (deletingAll) viewModel.deleteAllHistory()
                        else viewModel.deleteRecords(historySelection)
                        exitHistorySelection()
                    },
                )
            },
            dismissButton = {
                TextButton(onClick = { confirmDeleteHistory = false }) {
                    Text("Cancel")
                }
            },
        )
    }

    BackHandler(enabled = selectingHistory) { exitHistorySelection() }

    // Returning from the gateway screen after setup is complete drops back into
    // the app rather than the checklist.
    if (showingGateway) {
        BackHandler { showingGateway = false }
    }
}
