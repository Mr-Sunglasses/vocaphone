package com.vocahq.vocaphone.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.vocahq.vocaphone.BuildConfig

/**
 * The small set of setup steps required before dictation works, in the order
 * the checklist presents them. Which list applies depends on the build: the
 * keyboard path wants the VocaPhone IME, the X build floating-mic path wants the
 * accessibility disclosure, overlay permission, and the accessibility service
 * instead. Android settings are re-read every time the app is resumed because
 * the user can change any of them outside VocaPhone.
 */
enum class SetupStep(val label: String) {
    MICROPHONE("Microphone"),
    NOTIFICATIONS("Notifications"),
    KEYBOARD("VocaPhone keyboard"),
    DISCLOSURE("Accessibility disclosure"),
    OVERLAY("Display over other apps"),
    ACCESSIBILITY("Accessibility service"),
    GATEWAY("Speech source"),
}

/** Everything guided setup checks, re-read every time the app is resumed. */
data class SetupStatus(
    val microphone: Boolean = false,
    val notifications: Boolean = false,
    val keyboard: Boolean = false,
    val disclosureAccepted: Boolean = false,
    val overlay: Boolean = false,
    val accessibility: Boolean = false,
    val gatewayConfigured: Boolean = false,
    val ime: ImeSetupStatus = ImeSetupStatus(),
    val floating: FloatingSetupStatus = FloatingSetupStatus(),
    /** False only until the first settings and permission read completes. */
    val isLoaded: Boolean = true,
) {
    fun isSatisfied(step: SetupStep): Boolean = when (step) {
        SetupStep.MICROPHONE -> microphone
        SetupStep.NOTIFICATIONS -> notifications
        SetupStep.KEYBOARD -> keyboard
        SetupStep.DISCLOSURE -> disclosureAccepted
        SetupStep.OVERLAY -> overlay
        SetupStep.ACCESSIBILITY -> accessibility
        SetupStep.GATEWAY -> gatewayConfigured
    }

    /** The steps this build actually requires, in checklist order. */
    val requiredSteps: List<SetupStep>
        get() = if (BuildConfig.FLOATING_INPUT) FLOATING_STEPS else IME_STEPS

    /** What the checklist still wants, in checklist order, for a plain-English prompt. */
    val remainingSteps: List<SetupStep>
        get() = requiredSteps.filterNot(::isSatisfied)

    val stepCount: Int get() = requiredSteps.size

    val completedStepCount: Int get() = stepCount - remainingSteps.size

    val isReadyToDictate: Boolean
        get() = isLoaded && remainingSteps.isEmpty()

    /** Short labels for chips under the header progress. */
    val remainingLabels: List<String>
        get() = remainingSteps.map { it.label }

    companion object {
        private val IME_STEPS = listOf(
            SetupStep.MICROPHONE,
            SetupStep.NOTIFICATIONS,
            SetupStep.KEYBOARD,
            SetupStep.GATEWAY,
        )

        private val FLOATING_STEPS = listOf(
            SetupStep.DISCLOSURE,
            SetupStep.MICROPHONE,
            SetupStep.NOTIFICATIONS,
            SetupStep.OVERLAY,
            SetupStep.ACCESSIBILITY,
            SetupStep.GATEWAY,
        )

        fun read(
            context: Context,
            gatewayConfigured: Boolean,
            disclosureAccepted: Boolean = false,
        ): SetupStatus {
            val ime = ImeSetup.read(context)
            val floating = FloatingSetup.read(context)
            return SetupStatus(
                microphone = context.hasPermission(Manifest.permission.RECORD_AUDIO),
                notifications = context.hasPermission(Manifest.permission.POST_NOTIFICATIONS),
                keyboard = ime.selected,
                disclosureAccepted = disclosureAccepted,
                overlay = floating.overlay,
                accessibility = floating.accessibility,
                gatewayConfigured = gatewayConfigured,
                ime = ime,
                floating = floating,
            )
        }
    }
}

private fun Context.hasPermission(permission: String) =
    ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
