package com.vocahq.vocaphone.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.padding
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.ui.theme.VocaPhoneTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VocaPhoneTheme {
                VocaPhoneApp()
            }
        }
    }
}

private enum class Destination(val label: String, @param:DrawableRes val icon: Int) {
    DICTATE("Dictate", R.drawable.ic_dictation),
    HISTORY("History", R.drawable.ic_history),
    SETTINGS("Settings", R.drawable.ic_settings),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VocaPhoneApp(viewModel: VocaPhoneViewModel = viewModel()) {
    val settings by viewModel.settings.collectAsStateWithLifecycle()
    val setup by viewModel.setup.collectAsStateWithLifecycle()
    val dictation by viewModel.dictation.collectAsStateWithLifecycle()
    val history by viewModel.history.collectAsStateWithLifecycle()
    val connection by viewModel.connection.collectAsStateWithLifecycle()
    val testing by viewModel.testing.collectAsStateWithLifecycle()
    val microphone by viewModel.microphone.collectAsStateWithLifecycle()
    val localModels by viewModel.localModels.collectAsStateWithLifecycle()

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

    var destination by remember { mutableStateOf(Destination.DICTATE) }
    var showingGateway by remember { mutableStateOf(false) }

    val showSetup = !settings.onboardingComplete && !showingGateway

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        when {
                            showingGateway -> "Gateway"
                            showSetup -> "Setup"
                            else -> destination.label
                        }
                    )
                },
                navigationIcon = {
                    // The gateway screen is pushed on top of setup, so it needs a
                    // visible way back; the system gesture alone is not discoverable.
                    if (showingGateway) {
                        IconButton(onClick = { showingGateway = false }) {
                            Icon(
                                painterResource(R.drawable.ic_back),
                                contentDescription = "Back",
                            )
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
                            onClick = { destination = entry },
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
                onLocalModel = viewModel::setLocalModel,
                onDownloadLocalModel = viewModel::downloadLocalModel,
                onCancelLocalModelDownload = viewModel::cancelLocalModelDownload,
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
                onMicrophone = { viewModel.setMicrophone(it) },
                onAudioRetention = { viewModel.setAudioRetention(it) },
                localModels = localModels,
                onLocalTranscriptionEnabled = viewModel::setLocalTranscriptionEnabled,
                onLocalModel = viewModel::setLocalModel,
                onDownloadLocalModel = viewModel::downloadLocalModel,
                onCancelLocalModelDownload = viewModel::cancelLocalModelDownload,
                onDeleteLocalModel = viewModel::deleteLocalModel,
                onOpenGateway = { showingGateway = true },
                diagnosticEvents = viewModel::diagnosticEvents,
                onClearDiagnosticEvents = viewModel::clearDiagnosticEvents,
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
