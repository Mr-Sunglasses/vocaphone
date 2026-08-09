package com.vocahq.vocaphone.ui

import android.content.ComponentName
import android.content.Context
import android.content.Intent
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

    fun openSettings(context: Context) {
        context.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
    }

    fun showPicker(context: Context) {
        context.getSystemService(InputMethodManager::class.java)?.showInputMethodPicker()
    }
}
