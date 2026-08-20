package com.vocahq.vocaphone.ui

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.StatFs
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.GatewayEndpoint
import com.vocahq.vocaphone.local.LOCAL_MODELS_DIR
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import java.io.File

const val ORG_URL = "https://github.com/VocaHQ"
const val PROJECT_URL = "https://github.com/VocaHQ/vocaphone"
const val WEBSITE_URL = "https://vocaphone.vocahq.com"
const val NEW_ISSUE_URL = "https://github.com/VocaHQ/vocaphone/issues/new/choose"
const val FAMILY_SITE_URL = "https://vocahq.com"
const val VOCALINUX_URL = "https://vocalinux.com"
const val VOCAMAC_URL = "https://vocamac.com"
const val VOCAGATEWAY_SITE_URL = "https://vocagateway.vocahq.com"
const val DISCORD_URL = "https://discord.gg/UMJduhcqn"
const val X_URL = "https://x.com/vocahq"
const val CONTACT_EMAIL = "hello@vocahq.com"
const val CONTACT_MAILTO = "mailto:hello@vocahq.com"

/** Quick start, engines, and pairing for a self-hosted gateway. */
const val GATEWAY_GUIDE_URL = "https://github.com/VocaHQ/vocagateway"

const val ABOUT_WORDMARK = "VocaPhone"
const val ABOUT_REPORT_BUG = "Report a bug or idea"
const val ABOUT_COPY_DIAGNOSTICS = "Copy diagnostics"
const val ABOUT_CLEAR_EVENT_LOG = "Clear event log"

const val ABOUT_TAGLINE = "Voice-to-text for Android, kept on this phone."

const val ABOUT_STATUS = "Public beta. Android 13 and newer."

const val ABOUT_ON_DEVICE =
    "Speech is transcribed on this phone first. A gateway is optional " +
        "self-hosted compute. On-device dictation never calls it."

const val ABOUT_FAMILY_NOTE =
    "VocaPhone is one of the VocaHQ apps. VocaLinux is available now, " +
        "VocaMac is in beta, and VocaWin is a developer alpha. This APK is " +
        "the Android beta. iOS 17+ is a source build in the same repo. " +
        "VocaGateway is Early."

const val ABOUT_FEEDBACK_NOTE =
    "Bugs, feedback, and feature ideas open a new GitHub issue. You pick the " +
        "template on the next screen."

/**
 * A tap target on About.
 *
 * [icon] is a VocaDesign vocahq/social mark. Do not invent brand marks here.
 */
data class AboutLink(
    val label: String,
    val url: String,
    val icon: Int? = null,
)

val ABOUT_FAMILY_LINKS = listOf(
    AboutLink("vocahq.com", FAMILY_SITE_URL),
    AboutLink("vocalinux.com", VOCALINUX_URL),
    AboutLink("vocamac.com", VOCAMAC_URL),
    AboutLink("vocaphone.vocahq.com", WEBSITE_URL),
    AboutLink("vocagateway.vocahq.com", VOCAGATEWAY_SITE_URL),
)

val ABOUT_CONTACT_LINKS = listOf(
    AboutLink("Discord", DISCORD_URL, R.drawable.ic_social_discord),
    AboutLink("X", X_URL, R.drawable.ic_social_x),
    AboutLink("Email", CONTACT_MAILTO, R.drawable.ic_social_mail),
)

const val ABOUT_PRIVACY_NOTE =
    "The keyboard types through Android's text connection. Dictation does not " +
        "read the field. With Suggestions on, the keyboard looks at about 32 " +
        "characters around the cursor on this phone.\n\n" +
        "Audio goes to a model on this phone or to the gateway you set up. " +
        "There is no cloud transcription. Usage reporting is off unless you " +
        "turn it on under Dictation, and then it sends counters only."

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
    val cpuFeatures: List<String> = emptyList(),
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
        cpuFeatures = runCatching { File(PROC_CPUINFO).readText() }
            .map(::cpuFeatures)
            .getOrDefault(emptyList()),
        performanceClass = Build.VERSION.MEDIA_PERFORMANCE_CLASS,
    )
}

private const val PROC_CPUINFO = "/proc/cpuinfo"

/**
 * The instruction-set extensions the transcription engines choose kernels from,
 * always reported in this order so two reports compare line for line.
 *
 * The pair that earns the line is sme without sme2. They are separate
 * extensions, and a core that has the first but not the second is what made
 * ONNX Runtime 1.23.2 dispatch SME2 opcodes and take the process down with
 * SIGILL on the Snapdragon 8 Elite Gen 5. Nothing in the old report said which
 * of the two the phone had.
 */
private val REPORTED_CPU_FEATURES = listOf(
    "asimdhp",
    "asimddp",
    "i8mm",
    "bf16",
    "sve",
    "sve2",
    "sme",
    "sme2",
)

/**
 * Reads the "Features" lines of a /proc/cpuinfo, which every core repeats.
 *
 * A closed allowlist, like every other field in a diagnostics report: the file
 * is free text from the kernel and the OEM, and the report gets pasted into
 * public issues, so a name this does not know is dropped rather than copied.
 */
fun cpuFeatures(cpuinfo: String): List<String> {
    val present = cpuinfo.lineSequence()
        .filter { it.substringBefore(':').trim() == "Features" }
        .flatMap { it.substringAfter(':', "").trim().splitToSequence(Regex("\\s+")) }
        .toSet()
    return REPORTED_CPU_FEATURES.filter { it in present }
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
        if (onDevice.cpuFeatures.isNotEmpty()) {
            add("CPU features: ${onDevice.cpuFeatures.joinToString()}")
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
