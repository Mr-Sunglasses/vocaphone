package io.github.mrsunglasses.localflow.ui

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.github.mrsunglasses.localflow.accessibility.LocalFlowAccessibilityService
import io.github.mrsunglasses.localflow.core.RestrictedSettingsPolicy

/**
 * A step guided setup requires before dictation can work, in the order the
 * checklist presents them. Battery is deliberately absent: it is offered,
 * never required.
 */
enum class SetupStep(val label: String) {
    DISCLOSURE("Accessibility disclosure"),
    MICROPHONE("Microphone"),
    NOTIFICATIONS("Notifications"),
    OVERLAY("Display over other apps"),
    ACCESSIBILITY("Accessibility service"),
    GATEWAY("Gateway"),
}

/** Everything guided setup checks, re-read every time the app is resumed. */
data class SetupStatus(
    val microphone: Boolean = false,
    val notifications: Boolean = false,
    val overlay: Boolean = false,
    val accessibility: Boolean = false,
    val batteryUnrestricted: Boolean = false,
    val gatewayConfigured: Boolean = false,
    val disclosureAccepted: Boolean = false,
    /** The accessibility switch is probably greyed out; see [RestrictedSettingsPolicy]. */
    val restrictedSettingsGuidance: Boolean = false,
) {
    fun isSatisfied(step: SetupStep): Boolean = when (step) {
        SetupStep.DISCLOSURE -> disclosureAccepted
        SetupStep.MICROPHONE -> microphone
        SetupStep.NOTIFICATIONS -> notifications
        SetupStep.OVERLAY -> overlay
        SetupStep.ACCESSIBILITY -> accessibility
        SetupStep.GATEWAY -> gatewayConfigured
    }

    /** What the checklist still wants, in checklist order, for a plain-English prompt. */
    val remainingSteps: List<SetupStep>
        get() = SetupStep.entries.filterNot(::isSatisfied)

    val stepCount: Int get() = SetupStep.entries.size

    val completedStepCount: Int get() = stepCount - remainingSteps.size

    val isReadyToDictate: Boolean
        get() = remainingSteps.isEmpty()

    companion object {
        fun read(context: Context, gatewayConfigured: Boolean, disclosureAccepted: Boolean): SetupStatus {
            val accessibility = context.isAccessibilityServiceEnabled()
            return SetupStatus(
                microphone = context.hasPermission(Manifest.permission.RECORD_AUDIO),
                notifications = context.hasPermission(Manifest.permission.POST_NOTIFICATIONS),
                overlay = Settings.canDrawOverlays(context),
                accessibility = accessibility,
                batteryUnrestricted = context.isBatteryUnrestricted(),
                gatewayConfigured = gatewayConfigured,
                disclosureAccepted = disclosureAccepted,
                restrictedSettingsGuidance = RestrictedSettingsPolicy.guidanceNeeded(
                    sdkInt = Build.VERSION.SDK_INT,
                    installerPackage = context.installerPackage(),
                    accessibilityGranted = accessibility,
                ),
            )
        }
    }
}

/**
 * Null covers both an install that recorded no originator and a read that
 * failed outright; either way the app cannot claim it came from a store.
 */
internal fun Context.installerPackage(): String? = runCatching {
    packageManager.getInstallSourceInfo(packageName).installingPackageName
}.getOrNull()

private fun Context.hasPermission(permission: String) =
    ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

private fun Context.isBatteryUnrestricted() =
    getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(packageName) ?: false

/**
 * Read from Settings.Secure rather than tracked in the app: the user can turn
 * the service off from system settings at any time, and the repair prompt has to
 * notice when they do.
 */
internal fun Context.isAccessibilityServiceEnabled(): Boolean {
    val expected = ComponentName(this, LocalFlowAccessibilityService::class.java)
    val enabled = Settings.Secure.getString(
        contentResolver,
        Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
    ).orEmpty()
    return enabled.split(':').any { entry ->
        ComponentName.unflattenFromString(entry) == expected
    }
}
