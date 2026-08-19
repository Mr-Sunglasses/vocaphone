package com.vocahq.vocaphone.ui

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.os.Build
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import com.vocahq.vocaphone.ime.VocaPhoneInputMethodService

data class ImeSetupStatus(
    val enabled: Boolean = false,
    val selected: Boolean = false,
)

/** System handoff helpers for the keyboard experiment. */
object ImeSetup {

    fun read(context: Context): ImeSetupStatus {
        val component = ComponentName(context, VocaPhoneInputMethodService::class.java)
        // Android 14+ blocks ordinary target-SDK 34+ apps from reading the raw
        // ENABLED_INPUT_METHODS secure setting. InputMethodManager is the public
        // API for the same information and works for targetSdk 36.
        val manager = context.getSystemService(InputMethodManager::class.java)

        return ImeSetupStatus(
            enabled = manager?.enabledInputMethodList.orEmpty().any { info ->
                info.packageName == component.packageName && info.serviceName == component.className
            },
            selected = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                manager?.currentInputMethodInfo?.let { info ->
                    info.packageName == component.packageName && info.serviceName == component.className
                } == true
            } else {
                Settings.Secure.getString(
                    context.contentResolver,
                    Settings.Secure.DEFAULT_INPUT_METHOD,
                ) == component.flattenToString()
            },
        )
    }

    /**
     * The secure settings that change as someone turns the keyboard on and then
     * chooses it. Both are needed: the step is two system changes, and watching
     * only the second leaves the checklist stuck on the first.
     *
     * Watching these is what makes the checklist notice. Coming back to the app
     * is not a reliable signal for either half: the picker is a system dialog
     * drawn over an activity that never leaves the resumed state, so nothing
     * re-reads after it closes, and the settings screen commits its write
     * asynchronously, so a read taken the moment the app resumes can still see
     * the old value. Both leave the user staring at a step they have finished,
     * with reopening the app as the only way out.
     */
    val WATCHED_SETTINGS = listOf(
        Settings.Secure.ENABLED_INPUT_METHODS,
        Settings.Secure.DEFAULT_INPUT_METHOD,
    )

    /**
     * Registration is allowed to fail: these are secure settings, reading them
     * directly is already restricted on Android 14, and a ROM that refuses the
     * observer should cost the live update, not the onboarding screen.
     */
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

    fun openSettings(context: Context) {
        context.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
    }

    fun showPicker(context: Context) {
        context.getSystemService(InputMethodManager::class.java)?.showInputMethodPicker()
    }
}
