package com.vocahq.vocaphone.ui

import android.content.Context
import android.os.Build
import com.vocahq.vocaphone.core.GatewayEndpoint
import com.vocahq.vocaphone.settings.VocaPhoneSettings

const val PROJECT_URL = "https://github.com/VocaHQ/vocaphone"

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
 * Which store, if any, vouched for this install. It is the same signal guided
 * setup uses to predict a greyed-out accessibility switch, so it belongs in a
 * bug report.
 */
private fun Context.installerLabel(): String = when (val installer = installerPackage()) {
    null -> "sideloaded"
    "com.android.vending" -> "Google Play"
    "org.fdroid.fdroid" -> "F-Droid"
    else -> installer
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
): String = buildString {
    appendLine("VocaPhone ${info.versionName} (${info.versionCode})")
    appendLine("Android ${info.androidRelease} (SDK ${info.sdkInt}) · ${info.device}")
    appendLine("Installed from: ${info.installedFrom}")
    appendLine("Gateway: ${gatewaySummary(settings)}")
    appendLine("Engine: ${settings.lastEngine.ifEmpty { "unknown" }}" +
        if (settings.lastEngineReady) " (ready)" else " (not ready)")
    appendLine("Streaming: " + if (settings.lastStreamingSupported) "supported" else "batch upload")
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
}

/** Enough to debug a transport problem, without naming the host. */
private fun gatewaySummary(settings: VocaPhoneSettings): String = when {
    !settings.isConfigured -> "not configured"
    GatewayEndpoint.isCleartext(settings.gatewayUrl) -> "http:// (private host)"
    else -> "https://"
}
