package com.vocahq.vocaphone.ui

import android.app.Application
import android.database.ContentObserver
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.vocahq.vocaphone.VocaPhoneApplication
import com.vocahq.vocaphone.audio.InputDevices
import com.vocahq.vocaphone.audio.TonePreview
import com.vocahq.vocaphone.core.DictationTone
import com.vocahq.vocaphone.core.GatewayEndpoint
import com.vocahq.vocaphone.core.MicrophonePreference
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.data.DictationRecordEntity
import com.vocahq.vocaphone.dictation.DictationService
import com.vocahq.vocaphone.dictation.DictationSource
import com.vocahq.vocaphone.gateway.GatewayClient
import com.vocahq.vocaphone.gateway.GatewayException
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelIntegrityException
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.settings.AudioRetention
import com.vocahq.vocaphone.settings.KeyboardHeight
import com.vocahq.vocaphone.settings.SplitKeyboard
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import com.vocahq.vocaphone.telemetry.TelemetryDownloadOutcome
import com.vocahq.vocaphone.telemetry.TelemetrySetupStep
import com.vocahq.vocaphone.telemetry.TelemetrySource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** The outcome of a connection test, shown in full so nothing is guessed at. */
data class ConnectionReport(
    val reachable: Boolean,
    val tokenValid: Boolean,
    val engine: String,
    val engineReady: Boolean,
    val streamingSupported: Boolean?,
    val message: String,
)

/**
 * What the Microphone setting can offer right now. The route is only knowable
 * while capture holds the microphone, so it is remembered afterwards rather than
 * blanked — "last used" is a truthful answer, an empty line is not.
 */
data class MicrophoneStatus(
    val available: Set<MicrophonePreference> = setOf(MicrophonePreference.AUTOMATIC),
    val route: String? = null,
    val recording: Boolean = false,
) {
    /** Changing the input rebuilds the recorder, which a live dictation cannot survive. */
    val changeable: Boolean get() = !recording

    fun inUseLabel(preference: MicrophonePreference): String = when {
        route == null ->
            if (preference == MicrophonePreference.AUTOMATIC) {
                "Selected when recording starts"
            } else {
                preference.displayName
            }

        recording -> route
        else -> "Last used: $route"
    }
}

class VocaPhoneViewModel(application: Application) : AndroidViewModel(application) {

    private val container = VocaPhoneApplication.container(application)

    val settings: StateFlow<VocaPhoneSettings> = container.settings.settings
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), VocaPhoneSettings())

    val history: StateFlow<List<DictationRecordEntity>> = container.history.observeRecent()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val dictation = container.dictation.state
    val localModels: StateFlow<LocalModelState> = container.localModels.state

    private val _setup = MutableStateFlow(SetupStatus())
    val setup: StateFlow<SetupStatus> = _setup.asStateFlow()

    private val _connection = MutableStateFlow<ConnectionReport?>(null)
    val connection: StateFlow<ConnectionReport?> = _connection.asStateFlow()

    private val _testing = MutableStateFlow(false)
    val testing: StateFlow<Boolean> = _testing.asStateFlow()

    private val _microphone = MutableStateFlow(MicrophoneStatus())
    val microphone: StateFlow<MicrophoneStatus> = _microphone.asStateFlow()

    private val _tonePreviewListening = MutableStateFlow(false)
    val tonePreviewListening: StateFlow<Boolean> = _tonePreviewListening.asStateFlow()

    private val audioManager = application.getSystemService(AudioManager::class.java)
    private var localModelDownloadJob: Job? = null

    /** Superseded rather than queued: only the newest selection is worth loading. */
    private var localEnginePreloadJob: Job? = null

    /**
     * Headsets are plugged and unplugged while the settings screen is open, so the
     * offered inputs track the hardware rather than a snapshot taken at launch.
     * Registration fires the callback once with what is already attached.
     */
    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) = refreshMicrophones()

        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) = refreshMicrophones()
    }

    /**
     * Guided setup's keyboard step finishes outside the app, and neither half of
     * it reliably brings the activity back through onResume. The picker is a
     * system dialog drawn over an activity that stays resumed, so nothing
     * re-reads once it closes; and the settings screen commits its write
     * asynchronously, so a read taken on resume can still return the old value.
     * Either way the checklist keeps asking for a step the user has just
     * finished, and killing the app is the only way to move on.
     *
     * Watching the settings makes the state arrive rather than be sampled, so
     * the step ticks while they are still looking at it.
     */
    private val imeSettingsObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) = refreshSetup()
    }

    init {
        audioManager?.registerAudioDeviceCallback(deviceCallback, null)
        ImeSetup.watchSettings(application, imeSettingsObserver)
        container.telemetry.appFirstOpen()
        viewModelScope.launch {
            container.dictation.state.collect { state ->
                _microphone.update {
                    it.copy(route = state.inputRouteLabel ?: it.route, recording = state.isRecording)
                }
            }
        }
    }

    override fun onCleared() {
        audioManager?.unregisterAudioDeviceCallback(deviceCallback)
        ImeSetup.stopWatchingSettings(getApplication(), imeSettingsObserver)
        super.onCleared()
    }

    private fun refreshMicrophones() {
        val manager = audioManager ?: return
        _microphone.update { it.copy(available = InputDevices.available(manager)) }
    }

    fun refreshSetup() {
        viewModelScope.launch {
            val configuration = container.settings.current()
            _setup.value = SetupStatus.read(
                context = getApplication(),
                gatewayConfigured = configuration.isConfigured || (
                    configuration.localTranscriptionEnabled &&
                        container.localModels.isDownloaded(configuration.localModelId)
                    ),
            )
            reportSetupProgress(_setup.value)
        }
    }

    /**
     * Reports each setup step the first time it is satisfied.
     *
     * Driven from the refreshed status rather than from the buttons that grant
     * each permission, because most of these steps are completed in iOS-style
     * trips out to system Settings and come back as state, not as a callback.
     * Each step is a once-ever milestone inside [Telemetry], so repeatedly
     * refreshing a finished checklist reports nothing.
     */
    private fun reportSetupProgress(status: SetupStatus) {
        if (status.microphone) container.telemetry.setupStepCompleted(TelemetrySetupStep.MICROPHONE)
        if (status.notifications) {
            container.telemetry.setupStepCompleted(TelemetrySetupStep.NOTIFICATIONS)
        }
        if (status.ime.selected) container.telemetry.setupStepCompleted(TelemetrySetupStep.KEYBOARD)
        if (status.gatewayConfigured) {
            container.telemetry.setupStepCompleted(TelemetrySetupStep.SOURCE)
        }
    }

    // ------------------------------------------------------------- gateway

    fun saveGateway(url: String, token: String, onResult: (String?) -> Unit) {
        when (val validation = GatewayEndpoint.validate(url)) {
            is GatewayEndpoint.Validation.Invalid -> onResult(validation.reason)
            is GatewayEndpoint.Validation.Valid -> viewModelScope.launch {
                val trimmed = token.trim()
                if (trimmed.isEmpty() && !container.settings.current().hasToken) {
                    onResult("Enter the bearer token your gateway printed on first run.")
                    return@launch
                }
                // A blank token with one already stored means "keep it", which is
                // what the field promises. Correcting a typo in the address should
                // not require digging the secret out again.
                if (trimmed.isEmpty()) {
                    container.settings.setGatewayUrl(validation.url)
                } else {
                    container.settings.setGateway(validation.url, trimmed)
                }
                container.settings.setLocalTranscriptionEnabled(false)
                refreshSetup()
                testConnection()
                onResult(null)
            }
        }
    }

    fun clearGateway() {
        viewModelScope.launch {
            container.settings.clearGateway()
            _connection.value = null
            refreshSetup()
        }
    }

    fun testConnection() {
        if (_testing.value) return
        viewModelScope.launch {
            _testing.value = true
            _connection.value = runConnectionTest()
            _testing.value = false
        }
    }

    private suspend fun runConnectionTest(): ConnectionReport {
        val configuration = container.settings.current()
        val token = container.settings.token()
        if (configuration.gatewayUrl.isEmpty() || token.isNullOrEmpty()) {
            return ConnectionReport(
                reachable = false,
                tokenValid = false,
                engine = "",
                engineReady = false,
                streamingSupported = null,
                message = "Add your gateway address and token first.",
            )
        }
        val client = GatewayClient(configuration.gatewayUrl, token)
        val health = try {
            client.health()
        } catch (error: GatewayException) {
            return ConnectionReport(
                reachable = false,
                tokenValid = false,
                engine = "",
                engineReady = false,
                streamingSupported = null,
                message = error.userMessage,
            )
        }
        val tokenValid = try {
            client.verifyAuthentication()
            true
        } catch (error: GatewayException) {
            return ConnectionReport(
                reachable = true,
                tokenValid = false,
                engine = health.engine,
                engineReady = health.engineReady,
                streamingSupported = health.streamingSupported,
                message = error.userMessage,
            )
        }
        container.settings.recordEngineStatus(
            engine = health.engine,
            ready = health.engineReady,
            streamingSupported = health.streamingSupported == true,
            modelLanguages = health.languages,
            modelDetectsLanguage = health.detectsLanguageAutomatically,
        )
        return ConnectionReport(
            reachable = true,
            tokenValid = tokenValid,
            engine = health.engine,
            engineReady = health.engineReady,
            streamingSupported = health.streamingSupported,
            message = when {
                !health.engineReady -> "Connected, but no model is loaded yet. Select one in your gateway's Models page."
                else -> "Ready for dictation."
            },
        )
    }

    // ------------------------------------------------------------ settings

    fun setLanguage(language: TranscriptionLanguage) =
        viewModelScope.launch { container.settings.setLanguage(language) }

    fun setStyle(style: WritingStyle) =
        viewModelScope.launch { container.settings.setStyle(style) }

    fun setDictationTone(tone: DictationTone) {
        _tonePreviewListening.value = false
        viewModelScope.launch { container.settings.setDictationTone(tone) }
    }

    fun toggleDictationTonePreview(tone: DictationTone) {
        val next = TonePreview.nextListening(_tonePreviewListening.value, tone)
        if (!next) {
            if (_tonePreviewListening.value) {
                container.dictationCues.haptic()
                container.dictationCues.stopCue(tone)
            }
            _tonePreviewListening.value = false
            return
        }
        container.dictationCues.haptic()
        container.dictationCues.startCue(tone)
        _tonePreviewListening.value = true
    }

    fun setTranscriptionQuality(quality: TranscriptionQuality) =
        viewModelScope.launch {
            container.settings.setTranscriptionQuality(quality)
            // A sherpa engine has the decoding method baked in, so this rebuilds
            // it. Doing that here means it happens while the user is still on
            // this screen rather than in front of the next dictation.
            preloadLocalEngine()
        }

    fun setCustomVocabulary(vocabulary: String) =
        viewModelScope.launch { container.settings.setCustomVocabulary(vocabulary) }

    fun setMicrophone(preference: MicrophonePreference) {
        // Applied when the recorder is built, so a live dictation would keep the
        // old input while the screen claimed otherwise.
        if (_microphone.value.recording) return
        viewModelScope.launch {
            container.settings.setMicrophone(preference)
            // The remembered route described the previous selection.
            _microphone.update { it.copy(route = null) }
        }
    }

    fun setAudioRetention(retention: AudioRetention) =
        viewModelScope.launch { container.settings.setAudioRetention(retention) }

    fun setNumberRowEnabled(enabled: Boolean) =
        viewModelScope.launch { container.settings.setNumberRowEnabled(enabled) }

    fun setKeyboardHeight(height: KeyboardHeight) =
        viewModelScope.launch { container.settings.setKeyboardHeight(height) }

    fun setSplitKeyboard(mode: SplitKeyboard) =
        viewModelScope.launch { container.settings.setSplitKeyboard(mode) }

    fun setSuggestionsEnabled(enabled: Boolean) =
        viewModelScope.launch { container.settings.setSuggestionsEnabled(enabled) }

    fun setCorrectionsEnabled(enabled: Boolean) =
        viewModelScope.launch { container.settings.setCorrectionsEnabled(enabled) }

    fun setNumberKeyHintsEnabled(enabled: Boolean) =
        viewModelScope.launch { container.settings.setNumberKeyHintsEnabled(enabled) }

    fun setLongPressSymbolsEnabled(enabled: Boolean) =
        viewModelScope.launch { container.settings.setLongPressSymbolsEnabled(enabled) }

    fun setPersonalDictionary(words: String) =
        viewModelScope.launch {
            container.settings.setPersonalDictionary(
                com.vocahq.vocaphone.ime.PersonalDictionary.normalize(words),
            )
        }

    fun setAsciiEmojiEnabled(enabled: Boolean) =
        viewModelScope.launch { container.settings.setAsciiEmojiEnabled(enabled) }

    fun setSwipeTypingEnabled(enabled: Boolean) =
        viewModelScope.launch { container.settings.setSwipeTypingEnabled(enabled) }

    fun setClipboardChipEnabled(enabled: Boolean) =
        viewModelScope.launch { container.settings.setClipboardChipEnabled(enabled) }

    fun setClipboardHistoryEnabled(enabled: Boolean) =
        viewModelScope.launch { container.settings.setClipboardHistoryEnabled(enabled) }

    fun clearClipboardHistory() =
        viewModelScope.launch { container.settings.clearClipboardHistory() }

    fun setOnboardingComplete(complete: Boolean) =
        viewModelScope.launch {
            container.settings.setOnboardingComplete(complete)
            if (complete) container.telemetry.setupFinished()
        }

    fun setLocalTranscriptionEnabled(enabled: Boolean) =
        viewModelScope.launch {
            container.settings.setLocalTranscriptionEnabled(enabled)
            container.telemetry.sourceSelected(
                if (enabled) TelemetrySource.ON_DEVICE else TelemetrySource.GATEWAY
            )
            refreshSetup()
        }

    // ----------------------------------------------------------- telemetry

    /** Anonymous usage reporting; see `TelemetryConfig` for what this does and does not send. */
    fun setTelemetryEnabled(enabled: Boolean) = container.telemetry.setEnabled(enabled)

    /** Records that the onboarding step was shown, whichever way it was answered. */
    fun setTelemetryAsked() =
        viewModelScope.launch { container.settings.setTelemetryAsked(true) }

    /** The literal JSON the next flush would POST, for the "See what's sent" screen. */
    fun telemetryPayload(): String = container.telemetry.pendingPayload()

    fun telemetryPendingCount(): Int = container.telemetry.pendingCount()

    /** Whether reporting is actually getting through; counts only, no content. */
    fun telemetryDeliveryStatus(): String = container.telemetry.deliveryStatus()

    fun telemetryInspect() = container.telemetry.inspectPayload()

    fun setLocalModel(model: LocalModelDescriptor) {
        viewModelScope.launch {
            container.settings.setLocalModel(model.id)
            container.settings.setLocalTranscriptionEnabled(true)
            refreshSetup()
            preloadLocalEngine()
        }
    }

    /**
     * Warms the selected on-device engine. Best effort throughout: a failure
     * here is silent because the dictation that follows will attempt the same
     * load and report whatever went wrong in a place the user is looking.
     */
    private fun preloadLocalEngine() {
        localEnginePreloadJob?.cancel()
        localEnginePreloadJob = viewModelScope.launch {
            val configuration = container.settings.current()
            if (!configuration.localTranscriptionEnabled) return@launch
            val modelID = configuration.localModelId.takeIf { it.isNotEmpty() } ?: return@launch
            runCatching {
                container.localModels.prepare(
                    modelID = modelID,
                    language = configuration.effectiveLanguage.wireValue,
                    quality = configuration.transcriptionQuality,
                )
            }
        }
    }

    fun downloadLocalModel(model: LocalModelDescriptor) {
        startLocalModelDownload(model, useWhenReady = false)
    }

    fun downloadAndUseLocalModel(model: LocalModelDescriptor) {
        startLocalModelDownload(model, useWhenReady = true)
    }

    private fun startLocalModelDownload(model: LocalModelDescriptor, useWhenReady: Boolean) {
        val job = container.localModels.startDownload(model)
        localModelDownloadJob = job
        job.invokeOnCompletion { cause ->
            if (localModelDownloadJob === job) localModelDownloadJob = null
            when {
                cause is CancellationException ->
                    container.telemetry.modelDownloadFinished(
                        model,
                        TelemetryDownloadOutcome.CANCELLED,
                    )
                cause != null ->
                    container.telemetry.modelDownloadFinished(
                        model,
                        if (cause is LocalModelIntegrityException ||
                            cause.cause is LocalModelIntegrityException
                        ) {
                            TelemetryDownloadOutcome.INTEGRITY_FAILED
                        } else {
                            TelemetryDownloadOutcome.FAILED
                        },
                    )
                else -> {
                    container.telemetry.modelDownloadFinished(
                        model,
                        TelemetryDownloadOutcome.COMPLETED,
                    )
                    if (useWhenReady) {
                        container.workScope.launch {
                            container.settings.setLocalModel(model.id)
                            container.settings.setLocalTranscriptionEnabled(true)
                            refreshSetup()
                            preloadLocalEngine()
                        }
                    }
                }
            }
        }
    }

    fun cancelLocalModelDownload() {
        container.localModels.cancelDownload()
        localModelDownloadJob?.cancel()
        localModelDownloadJob = null
    }

    fun deleteLocalModel(model: LocalModelDescriptor) {
        viewModelScope.launch { runCatching { container.localModels.delete(model) } }
    }

    // ----------------------------------------------------------- dictation

    fun startInAppDictation() =
        DictationService.start(getApplication(), DictationSource.COMPANION_APP)

    fun finishDictation() =
        DictationService.send(getApplication(), DictationService.ACTION_FINISH)

    fun cancelDictation() =
        DictationService.send(getApplication(), DictationService.ACTION_CANCEL)

    fun retry(sessionId: String) = container.dictation.retry(sessionId)

    fun dismissDictation() = container.dictation.clearTransient()

    fun deleteRecord(sessionId: String) =
        viewModelScope.launch { container.history.delete(sessionId) }

    fun deleteRecords(sessionIds: Collection<String>) = viewModelScope.launch {
        sessionIds.forEach { container.history.delete(it) }
    }

    fun deleteAllHistory() = viewModelScope.launch { container.history.deleteAll() }

    fun diagnosticEvents(): String = container.diagnostics.read()

    fun clearDiagnosticEvents() = container.diagnostics.clear()
}
