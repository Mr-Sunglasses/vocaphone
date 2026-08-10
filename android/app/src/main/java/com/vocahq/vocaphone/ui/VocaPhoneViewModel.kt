package com.vocahq.vocaphone.ui

import android.app.Application
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.vocahq.vocaphone.VocaPhoneApplication
import com.vocahq.vocaphone.audio.InputDevices
import com.vocahq.vocaphone.core.GatewayEndpoint
import com.vocahq.vocaphone.core.MicrophonePreference
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.data.DictationRecordEntity
import com.vocahq.vocaphone.dictation.DictationService
import com.vocahq.vocaphone.dictation.DictationSource
import com.vocahq.vocaphone.gateway.GatewayClient
import com.vocahq.vocaphone.gateway.GatewayException
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.settings.AudioRetention
import com.vocahq.vocaphone.settings.VocaPhoneSettings
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

    private val audioManager = application.getSystemService(AudioManager::class.java)
    private var localModelDownloadJob: Job? = null

    /**
     * Headsets are plugged and unplugged while the settings screen is open, so the
     * offered inputs track the hardware rather than a snapshot taken at launch.
     * Registration fires the callback once with what is already attached.
     */
    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) = refreshMicrophones()

        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) = refreshMicrophones()
    }

    init {
        audioManager?.registerAudioDeviceCallback(deviceCallback, null)
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
        container.localModels.cancelDownload()
        localModelDownloadJob?.cancel()
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

    fun setOnboardingComplete(complete: Boolean) =
        viewModelScope.launch { container.settings.setOnboardingComplete(complete) }

    fun setLocalTranscriptionEnabled(enabled: Boolean) =
        viewModelScope.launch {
            container.settings.setLocalTranscriptionEnabled(enabled)
            refreshSetup()
        }

    fun setLocalModel(model: LocalModelDescriptor) {
        viewModelScope.launch {
            container.settings.setLocalModel(model.id)
            container.settings.setLocalTranscriptionEnabled(true)
            refreshSetup()
        }
    }

    fun downloadLocalModel(model: LocalModelDescriptor) {
        cancelLocalModelDownload()
        val job = viewModelScope.launch {
            try {
                container.localModels.download(model)
            } catch (_: CancellationException) {
                // Cancellation is an explicit user action, not a failed download.
            }
        }
        localModelDownloadJob = job
        job.invokeOnCompletion {
            if (localModelDownloadJob === job) localModelDownloadJob = null
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

    fun deleteAllHistory() = viewModelScope.launch { container.history.deleteAll() }

    fun diagnosticEvents(): String = container.diagnostics.read()

    fun clearDiagnosticEvents() = container.diagnostics.clear()
}
