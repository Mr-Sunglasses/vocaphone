package com.vocahq.vocaphone.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

/**
 * The small set of setup steps required by the keyboard path. Android settings
 * are re-read every time the app is resumed because the user can change the
 * selected keyboard outside VocaPhone.
 */
enum class SetupStep(val label: String) {
    MICROPHONE("Microphone"),
    NOTIFICATIONS("Notifications"),
    KEYBOARD("VocaPhone keyboard"),
    GATEWAY("Gateway"),
}

/** Everything guided setup checks, re-read every time the app is resumed. */
data class SetupStatus(
    val microphone: Boolean = false,
    val notifications: Boolean = false,
    val keyboard: Boolean = false,
    val gatewayConfigured: Boolean = false,
    val ime: ImeSetupStatus = ImeSetupStatus(),
) {
    fun isSatisfied(step: SetupStep): Boolean = when (step) {
        SetupStep.MICROPHONE -> microphone
        SetupStep.NOTIFICATIONS -> notifications
        SetupStep.KEYBOARD -> keyboard
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
        fun read(context: Context, gatewayConfigured: Boolean): SetupStatus {
            val ime = ImeSetup.read(context)
            return SetupStatus(
                microphone = context.hasPermission(Manifest.permission.RECORD_AUDIO),
                notifications = context.hasPermission(Manifest.permission.POST_NOTIFICATIONS),
                keyboard = ime.selected,
                gatewayConfigured = gatewayConfigured,
                ime = ime,
            )
        }
    }
}

private fun Context.hasPermission(permission: String) =
    ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
