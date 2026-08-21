package com.vocahq.vocaphone.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
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

@OptIn(ExperimentalMaterial3Api::class)
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

    Scaffold(
        contentWindowInsets = WindowInsets.safeDrawing,
        topBar = {
            TopAppBar(
                title = {
                    val titleText = when {
                        showingGateway -> "Gateway"
                        showSetup -> "Setup"
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
                },
                navigationIcon = {
                    when {
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
            )
        },
        bottomBar = {
            if (!showSetup && !showingGateway) {
                NavigationBar {
                    Destination.entries.forEach { entry ->
                        NavigationBarItem(
                            selected = destination == entry,
                            onClick = {
                                if (destination == Destination.SETTINGS && entry == Destination.SETTINGS) {
                                    settingsPage = SettingsPage.HOME
                                }
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
                onRetry = viewModel::retry,
                onDelete = { viewModel.deleteRecord(it) },
                onDeleteAll = viewModel::deleteAllHistory,
                modifier = content,
            )

            else -> SettingsScreen(
                settings = settings,
                setup = setup,
                microphone = microphone,
                onLanguage = { viewModel.setLanguage(it) },
                onStyle = { viewModel.setStyle(it) },
                onDictationTone = { viewModel.setDictationTone(it) },
                onPreviewDictationTone = { viewModel.toggleDictationTonePreview(it) },
                tonePreviewListening = tonePreviewListening,
                onMicrophone = { viewModel.setMicrophone(it) },
                onAudioRetention = { viewModel.setAudioRetention(it) },
                onTranscriptionQuality = { viewModel.setTranscriptionQuality(it) },
                onCustomVocabulary = { viewModel.setCustomVocabulary(it) },
                onNumberRow = { viewModel.setNumberRowEnabled(it) },
                onKeyboardHeight = { viewModel.setKeyboardHeight(it) },
                onSplitKeyboard = { viewModel.setSplitKeyboard(it) },
                onSuggestions = { viewModel.setSuggestionsEnabled(it) },
                onCorrections = { viewModel.setCorrectionsEnabled(it) },
                onNumberKeyHints = { viewModel.setNumberKeyHintsEnabled(it) },
                onAsciiEmoji = { viewModel.setAsciiEmojiEnabled(it) },
                onSwipeTyping = { viewModel.setSwipeTypingEnabled(it) },
                onClipboardChip = { viewModel.setClipboardChipEnabled(it) },
                onClipboardHistory = { viewModel.setClipboardHistoryEnabled(it) },
                onClearClipboardHistory = { viewModel.clearClipboardHistory() },
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

    // Returning from the gateway screen after setup is complete drops back into
    // the app rather than the checklist.
    if (showingGateway) {
        BackHandler { showingGateway = false }
    }
}
