package com.vocahq.vocaphone.ui

import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.vocahq.vocaphone.accessibility.isAccessibilityServiceEnabled
import com.vocahq.vocaphone.core.RestrictedSettingsPolicy

/** System-state snapshot for the X build floating-mic path. */
data class FloatingSetupStatus(
    /** "Display over other apps" — the bubble cannot draw without it. */
    val overlay: Boolean = false,
    /** The accessibility service bound and enabled in system settings. */
    val accessibility: Boolean = false,
    /** Sideloaded install on Android 13+: the switch is probably greyed out. */
    val restrictedSettingsGuidance: Boolean = false,
)

/** System handoff helpers for the floating-mic (overlay + accessibility) path. */
object FloatingSetup {

    fun read(context: Context): FloatingSetupStatus {
        val accessibility = context.isAccessibilityServiceEnabled()
        return FloatingSetupStatus(
            overlay = Settings.canDrawOverlays(context),
            accessibility = accessibility,
            restrictedSettingsGuidance = RestrictedSettingsPolicy.guidanceNeeded(
                sdkInt = Build.VERSION.SDK_INT,
                installerPackage = context.installerPackage(),
                accessibilityGranted = accessibility,
            ),
        )
    }

    /**
     * Accessibility enablement commits to a secure setting; watching it makes
     * the checklist tick while the user is still on the system screen, same
     * reason ImeSetup watches its own pair. Overlay state has no observable
     * setting URI, so it is re-read on resume like before.
     */
    val WATCHED_SETTINGS = listOf(
        Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
    )

    fun watchSettings(context: Context, observer: ContentObserver) {
        WATCHED_SETTINGS.forEach { name ->
            runCatching {
                context.contentResolver.registerContentObserver(
                    Settings.Secure.getUriFor(name),
                    false,
                    observer,
                )
            }
        }
    }

    fun stopWatchingSettings(context: Context, observer: ContentObserver) {
        runCatching { context.contentResolver.unregisterContentObserver(observer) }
    }

    fun openOverlaySettings(context: Context) {
        context.startActivity(
            Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.fromParts("package", context.packageName, null),
            ),
        )
    }

    fun openAccessibilitySettings(context: Context) {
        context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
    }

    fun openAppSettings(context: Context) {
        context.startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            ),
        )
    }
}

/**
 * Null covers both an install that recorded no originator and a read that
 * failed outright; either way the app cannot claim it came from a store.
 */
internal fun Context.installerPackage(): String? = runCatching {
    packageManager.getInstallSourceInfo(packageName).installingPackageName
}.getOrNull()
