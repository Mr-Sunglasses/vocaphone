package com.vocahq.vocaphone.ui

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.StatFs
import com.vocahq.vocaphone.core.GatewayEndpoint
import com.vocahq.vocaphone.local.LOCAL_MODELS_DIR
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import java.io.File

const val ORG_URL = "https://github.com/VocaHQ"
const val PROJECT_URL = "https://github.com/VocaHQ/vocaphone"
const val WEBSITE_URL = "https://vocaphone.vocahq.com"
const val NEW_ISSUE_URL = "https://github.com/VocaHQ/vocaphone/issues/new/choose"

/** Quick start, engines, and pairing for a self-hosted gateway. */
const val GATEWAY_GUIDE_URL = "https://github.com/VocaHQ/vocagateway"

const val ABOUT_TAGLINE = "Voice dictation for Android and iPhone."

const val ABOUT_FAMILY_NOTE =
    "VocaPhone is one of the VocaHQ apps. The same dictation already runs on " +
        "Linux as VocaLinux and on macOS as VocaMac. Windows is on the way, " +
        "and the iPhone build lives in this project too."

const val ABOUT_FEEDBACK_NOTE =
    "Bugs, feedback, and feature ideas open a new GitHub issue. You pick the " +
        "template on the next screen."

const val ABOUT_PRIVACY_NOTE =
    "The keyboard types through Android's text connection. Dictation does not " +
        "read the field.\n\n" +
        "With Suggestions on, the keyboard looks at about 32 characters before " +
        "and after the cursor so it can guess the next word. That snippet stays " +
        "on this phone. It is not logged and it is not sent to the gateway. " +
        "Swipe typing compares your finger path to the English word list on the " +
        "phone and does not read the field.\n\n" +
        "The clipboard chip and history read clips only on this phone, and only " +
        "while the keyboard is open. Long-press the chip to hide it. Those clips " +
        "are never logged.\n\n" +
        "Audio goes to a model on this phone or to the gateway you set up. There " +
        "is no cloud transcription and no third-party analytics. Usage reporting " +
        "is off unless you turn it on under Dictation, and it sends counters to a " +
        "server VocaHQ self-hosts, never your speech or your text. Nothing is " +
        "copied to the clipboard unless you tap Copy."

const val ABOUT_DIAGNOSTICS_NOTE =
    "The copied report has the app version, setup state, and the hardware " +
        "numbers that matter for on-device models: RAM, free storage, CPU, and " +
        "how much space the downloaded models take. It does not include " +
        "transcripts, typed text, audio, gateway hosts, or tokens."

/** No browser is a plausible state on a stripped-down ROM, so failure is silent. */
fun Context.openHttpUrl(url: String) {
    runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
}

/** What the About card shows, read once from the platform. */
data class AppInfo(
    val versionName: String = "",
    val versionCode: Long = 0,
    val packageName: String = "",
    val installedFrom: String = "",
    val androidRelease: String = "",
    val sdkInt: Int = 0,
    val device: String = "",
)

fun Context.readAppInfo(): AppInfo {
    val info = runCatching { packageManager.getPackageInfo(packageName, 0) }.getOrNull()
    return AppInfo(
        versionName = info?.versionName.orEmpty(),
        versionCode = info?.longVersionCode ?: 0,
        packageName = packageName,
        installedFrom = installerLabel(),
        androidRelease = Build.VERSION.RELEASE.orEmpty(),
        sdkInt = Build.VERSION.SDK_INT,
        device = "${Build.MANUFACTURER} ${Build.MODEL}",
    )
}

/**
 * Which store, if any, vouched for this install. It is useful context in a bug
 * report, but it does not gate setup or request any special access.
 */
private fun Context.installerLabel(): String = when (val installer = runCatching {
    packageManager.getInstallSourceInfo(packageName).installingPackageName
}.getOrNull()) {
    null -> "sideloaded"
    "com.android.vending" -> "Google Play"
    "org.fdroid.fdroid" -> "F-Droid"
    else -> installer
}

/** Hardware and model-storage numbers that matter for on-device transcription. */
data class OnDeviceDiagnostics(
    val totalRamBytes: Long = 0,
    val availRamBytes: Long = 0,
    val totalStorageBytes: Long = 0,
    val availStorageBytes: Long = 0,
    val modelStorageBytes: Long = 0,
    val downloadedModelIds: List<String> = emptyList(),
    val cpuCores: Int = 0,
    val abi: String = "",
    val soc: String = "",
    val performanceClass: Int = 0,
) {
    val collected: Boolean
        get() = totalRamBytes > 0 || cpuCores > 0 || modelStorageBytes > 0 ||
            downloadedModelIds.isNotEmpty()
}

fun Context.readOnDeviceDiagnostics(
    downloadedModelIds: Set<String> = emptySet(),
): OnDeviceDiagnostics {
    val memory = ActivityManager.MemoryInfo()
    getSystemService(ActivityManager::class.java)?.getMemoryInfo(memory)
    val disk = runCatching { StatFs(filesDir.absolutePath) }.getOrNull()
    val models = File(filesDir, LOCAL_MODELS_DIR)
    return OnDeviceDiagnostics(
        totalRamBytes = memory.totalMem,
        availRamBytes = memory.availMem,
        totalStorageBytes = disk?.totalBytes ?: 0,
        availStorageBytes = disk?.availableBytes ?: 0,
        modelStorageBytes = directorySizeBytes(models),
        downloadedModelIds = downloadedModelIds.sorted(),
        cpuCores = Runtime.getRuntime().availableProcessors(),
        abi = Build.SUPPORTED_ABIS?.firstOrNull().orEmpty(),
        soc = socLabel(),
        performanceClass = Build.VERSION.MEDIA_PERFORMANCE_CLASS,
    )
}

fun directorySizeBytes(root: File): Long {
    if (!root.exists()) return 0
    return root.walkTopDown().filter { it.isFile }.sumOf { it.length() }
}

fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000L -> "%.1f GB".format(bytes / 1_000_000_000.0)
    bytes >= 1_000_000L -> "${bytes / 1_000_000} MB"
    bytes >= 1_000L -> "${bytes / 1_000} KB"
    else -> "$bytes B"
}

/**
 * A block the user can paste into an issue. The gateway host name is
 * deliberately left out — it is a LAN or tailnet address that identifies the
 * user's own network — and the bearer token never leaves the Keystore at all.
 */
fun diagnosticsReport(
    info: AppInfo,
    settings: VocaPhoneSettings,
    setup: SetupStatus,
    events: String = "",
    onDevice: OnDeviceDiagnostics = OnDeviceDiagnostics(),
): String = buildString {
    val localName = LocalModelCatalog.find(settings.localModelId)?.displayName
    val speech = speechSourceCopy(
        localEnabled = settings.localTranscriptionEnabled,
        localModelName = localName,
        gatewayConfigured = settings.isConfigured,
        gatewayUrl = settings.gatewayUrl,
        lastEngine = settings.lastEngine,
        lastEngineReady = settings.lastEngineReady,
    )
    appendLine("VocaPhone ${info.versionName} (${info.versionCode})")
    appendLine("Android ${info.androidRelease} (SDK ${info.sdkInt}) · ${info.device}")
    appendLine("Installed from: ${info.installedFrom}")
    appendLine("Speech: ${speech.engineLabel}")
    appendLine("Gateway: ${gatewaySummary(settings)}")
    if (!settings.localTranscriptionEnabled) {
        appendLine(
            "Engine: ${settings.lastEngine.ifEmpty { "unknown" }}" +
                if (settings.lastEngineReady) " (ready)" else " (not ready)",
        )
        appendLine("Streaming: " + if (settings.lastStreamingSupported) "supported" else "batch upload")
    } else {
        appendLine("Local model: ${settings.localModelId.ifEmpty { "none" }}")
        appendLine("Quality: ${settings.transcriptionQuality.displayName}")
    }
    onDeviceReportLines(onDevice).forEach { appendLine(it) }
    // Names the category asked for, not the device: a product name would put the
    // user's hardware into a report meant to be safe to paste publicly.
    appendLine("Microphone: ${settings.microphone.storedValue}")
    append("Setup: ")
    append(
        if (setup.isReadyToDictate) {
            "all steps done"
        } else {
            "missing ${setup.remainingSteps.joinToString { it.label }}"
        }
    )
    appendLine()
    appendLine("Keyboard: " + when {
        setup.ime.selected -> "enabled and selected"
        setup.ime.enabled -> "enabled, not selected"
        else -> "not enabled"
    })
    if (events.isNotBlank()) {
        appendLine("Event log:")
        append(events.trimEnd())
        appendLine()
    }
}

fun onDeviceReportLines(onDevice: OnDeviceDiagnostics): List<String> {
    if (!onDevice.collected) return emptyList()
    return buildList {
        add(
            "Downloaded models: " +
                if (onDevice.downloadedModelIds.isEmpty()) {
                    "none"
                } else {
                    "${onDevice.downloadedModelIds.joinToString()} (${onDevice.downloadedModelIds.size})"
                },
        )
        add("Model storage: ${formatBytes(onDevice.modelStorageBytes)}")
        if (onDevice.totalRamBytes > 0) {
            add(
                "RAM: ${formatBytes(onDevice.totalRamBytes)} total, " +
                    "${formatBytes(onDevice.availRamBytes)} available",
            )
        }
        if (onDevice.totalStorageBytes > 0) {
            add(
                "Storage: ${formatBytes(onDevice.availStorageBytes)} free of " +
                    formatBytes(onDevice.totalStorageBytes),
            )
        }
        if (onDevice.cpuCores > 0 || onDevice.abi.isNotEmpty()) {
            add(
                buildString {
                    append("CPU: ")
                    if (onDevice.cpuCores > 0) append("${onDevice.cpuCores} cores")
                    if (onDevice.abi.isNotEmpty()) {
                        if (onDevice.cpuCores > 0) append(" · ")
                        append(onDevice.abi)
                    }
                    if (onDevice.soc.isNotEmpty()) {
                        append(" · ")
                        append(onDevice.soc)
                    }
                },
            )
        }
        if (onDevice.performanceClass > 0) {
            add("Performance class: ${onDevice.performanceClass}")
        }
    }
}

private fun socLabel(): String {
    val fromSoc = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        listOf(Build.SOC_MANUFACTURER, Build.SOC_MODEL)
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString(" ")
    } else {
        ""
    }
    return fromSoc.ifEmpty { Build.HARDWARE.trim() }
}

/** Enough to debug a transport problem, without naming the host. */
private fun gatewaySummary(settings: VocaPhoneSettings): String = when {
    !settings.isConfigured -> "not configured"
    GatewayEndpoint.isCleartext(settings.gatewayUrl) -> "http:// (private host)"
    else -> "https://"
}
