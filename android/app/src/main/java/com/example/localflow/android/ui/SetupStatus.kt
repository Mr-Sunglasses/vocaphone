package com.example.localflow.android.ui

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.example.localflow.android.accessibility.LocalFlowAccessibilityService

/** Everything guided setup checks, re-read every time the app is resumed. */
data class SetupStatus(
    val microphone: Boolean = false,
    val notifications: Boolean = false,
    val overlay: Boolean = false,
    val accessibility: Boolean = false,
    val batteryUnrestricted: Boolean = false,
    val gatewayConfigured: Boolean = false,
    val disclosureAccepted: Boolean = false,
) {
    /** Battery is deliberately excluded: it is offered, never required. */
    val isReadyToDictate: Boolean
        get() = microphone && notifications && overlay && accessibility &&
            gatewayConfigured && disclosureAccepted

    companion object {
        fun read(context: Context, gatewayConfigured: Boolean, disclosureAccepted: Boolean) =
            SetupStatus(
                microphone = context.hasPermission(Manifest.permission.RECORD_AUDIO),
                notifications = context.hasPermission(Manifest.permission.POST_NOTIFICATIONS),
                overlay = Settings.canDrawOverlays(context),
                accessibility = context.isAccessibilityServiceEnabled(),
                batteryUnrestricted = context.isBatteryUnrestricted(),
                gatewayConfigured = gatewayConfigured,
                disclosureAccepted = disclosureAccepted,
            )
    }
}

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
