package io.github.mrsunglasses.localflow.ui

import android.app.Application
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.mrsunglasses.localflow.LocalFlowApplication
import io.github.mrsunglasses.localflow.core.GatewayEndpoint
import io.github.mrsunglasses.localflow.core.TranscriptionLanguage
import io.github.mrsunglasses.localflow.core.WritingStyle
import io.github.mrsunglasses.localflow.data.DictationRecordEntity
import io.github.mrsunglasses.localflow.dictation.DictationService
import io.github.mrsunglasses.localflow.dictation.DictationSource
import io.github.mrsunglasses.localflow.gateway.GatewayClient
import io.github.mrsunglasses.localflow.gateway.GatewayException
import io.github.mrsunglasses.localflow.settings.AudioRetention
import io.github.mrsunglasses.localflow.settings.BubbleBehavior
import io.github.mrsunglasses.localflow.settings.LocalFlowSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The outcome of a connection test, shown in full so nothing is guessed at. */
data class ConnectionReport(
    val reachable: Boolean,
    val tokenValid: Boolean,
    val engine: String,
    val engineReady: Boolean,
    val streamingSupported: Boolean?,
    val message: String,
)

data class InstalledApp(val packageName: String, val label: String)

class LocalFlowViewModel(application: Application) : AndroidViewModel(application) {

    private val container = LocalFlowApplication.container(application)

    val settings: StateFlow<LocalFlowSettings> = container.settings.settings
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), LocalFlowSettings())

    val history: StateFlow<List<DictationRecordEntity>> = container.history.observeRecent()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val dictation = container.dictation.state

    private val _setup = MutableStateFlow(SetupStatus())
    val setup: StateFlow<SetupStatus> = _setup.asStateFlow()

    private val _connection = MutableStateFlow<ConnectionReport?>(null)
    val connection: StateFlow<ConnectionReport?> = _connection.asStateFlow()

    private val _testing = MutableStateFlow(false)
    val testing: StateFlow<Boolean> = _testing.asStateFlow()

    private val _installedApps = MutableStateFlow<List<InstalledApp>>(emptyList())
    val installedApps: StateFlow<List<InstalledApp>> = _installedApps.asStateFlow()

    fun refreshSetup() {
        viewModelScope.launch {
            val configuration = container.settings.current()
            _setup.value = SetupStatus.read(
                context = getApplication(),
                gatewayConfigured = configuration.isConfigured,
                disclosureAccepted = configuration.disclosureAccepted,
            )
        }
    }

    // ------------------------------------------------------------- gateway

    fun saveGateway(url: String, token: String, onResult: (String?) -> Unit) {
        when (val validation = GatewayEndpoint.validate(url)) {
            is GatewayEndpoint.Validation.Invalid -> onResult(validation.reason)
            is GatewayEndpoint.Validation.Valid -> viewModelScope.launch {
                if (token.isBlank()) {
                    onResult("Enter the bearer token your gateway printed on first run.")
                    return@launch
                }
                container.settings.setGateway(validation.url, token.trim())
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

    fun setAutomaticInsertion(enabled: Boolean) =
        viewModelScope.launch { container.settings.setAutomaticInsertion(enabled) }

    fun setBubbleBehavior(behavior: BubbleBehavior) =
        viewModelScope.launch { container.settings.setBubbleBehavior(behavior) }

    fun setAudioRetention(retention: AudioRetention) =
        viewModelScope.launch { container.settings.setAudioRetention(retention) }

    fun setDisclosureAccepted(accepted: Boolean) = viewModelScope.launch {
        container.settings.setDisclosureAccepted(accepted)
        refreshSetup()
    }

    fun setOnboardingComplete(complete: Boolean) =
        viewModelScope.launch { container.settings.setOnboardingComplete(complete) }

    fun toggleExcludedApp(packageName: String) {
        viewModelScope.launch {
            val current = container.settings.current().excludedPackages
            val updated = if (packageName in current) current - packageName else current + packageName
            container.settings.setExcludedPackages(updated)
        }
    }

    fun loadInstalledApps() {
        if (_installedApps.value.isNotEmpty()) return
        viewModelScope.launch {
            _installedApps.value = withContext(Dispatchers.IO) { queryLauncherApps() }
        }
    }

    private fun queryLauncherApps(): List<InstalledApp> {
        val packageManager = getApplication<Application>().packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return packageManager
            .queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0))
            .mapNotNull { resolved ->
                val info: ApplicationInfo = resolved.activityInfo?.applicationInfo ?: return@mapNotNull null
                if (info.packageName == getApplication<Application>().packageName) return@mapNotNull null
                InstalledApp(info.packageName, packageManager.getApplicationLabel(info).toString())
            }
            .distinctBy { it.packageName }
            .sortedBy { it.label.lowercase() }
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
}
