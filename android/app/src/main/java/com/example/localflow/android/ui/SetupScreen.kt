package com.example.localflow.android.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Guided setup. Every step states what Local Flow does with the access it asks
 * for, and the accessibility disclosure is a separate, explicit consent rather
 * than a line buried in a list.
 */
@Composable
fun SetupScreen(
    status: SetupStatus,
    onOpenGateway: () -> Unit,
    onAcceptDisclosure: () -> Unit,
    onFinish: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val requestPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Set up Local Flow", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Local Flow dictates into any app through a floating bubble. Your " +
                "keyboard stays exactly as it is, and speech is transcribed only by " +
                "the gateway you run yourself.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        AccessibilityDisclosureCard(
            accepted = status.disclosureAccepted,
            onAccept = onAcceptDisclosure,
        )

        SectionCard("Permissions") {
            ChecklistRow(
                title = "Microphone",
                detail = "Records only while you are dictating.",
                satisfied = status.microphone,
                actionLabel = "Grant",
                onAction = { requestPermission.launch(Manifest.permission.RECORD_AUDIO) },
            )
            ChecklistRow(
                title = "Notifications",
                detail = "Shows the ongoing recording notification Android requires.",
                satisfied = status.notifications,
                actionLabel = "Grant",
                onAction = { requestPermission.launch(Manifest.permission.POST_NOTIFICATIONS) },
            )
            ChecklistRow(
                title = "Display over other apps",
                detail = "Draws the dictation bubble above the app you are typing in.",
                satisfied = status.overlay,
                actionLabel = "Open",
                onAction = { context.openOverlaySettings() },
            )
            ChecklistRow(
                title = "Accessibility service",
                detail = "Finds the focused field and inserts your transcript.",
                satisfied = status.accessibility,
                actionLabel = "Open",
                onAction = { context.openAccessibilitySettings() },
            )
            ChecklistRow(
                title = "Unrestricted battery usage (optional)",
                detail = "Stops Android ending a long dictation early.",
                satisfied = status.batteryUnrestricted,
                actionLabel = "Open",
                onAction = { context.openBatterySettings() },
            )
        }

        SectionCard("Gateway", supporting = "Your self-hosted Local Flow server.") {
            ChecklistRow(
                title = "Address and token",
                detail = "A LAN, Tailscale or HTTPS gateway you control.",
                satisfied = status.gatewayConfigured,
                actionLabel = "Set up",
                onAction = onOpenGateway,
            )
            if (status.gatewayConfigured) {
                TextButton(onClick = onOpenGateway) { Text("Change gateway") }
            }
        }

        Button(
            onClick = onFinish,
            enabled = status.isReadyToDictate,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (status.isReadyToDictate) "Start dictating" else "Finish the steps above")
        }
    }
}

/**
 * The prominent disclosure Play requires from a non-accessibility tool that uses
 * `AccessibilityService`. It is deliberately separate from the checklist and
 * states the limits, not just the purpose.
 */
@Composable
fun AccessibilityDisclosureCard(
    accepted: Boolean,
    onAccept: () -> Unit,
    modifier: Modifier = Modifier,
) {
    SectionCard(
        title = "How Local Flow uses accessibility access",
        modifier = modifier,
    ) {
        Text(
            "Local Flow turns on Android's accessibility service for two things:\n\n" +
                "• To tell whether the text field you are focused on can be dictated " +
                "into, so the bubble appears only where it is useful.\n" +
                "• To insert the transcript you asked for at your cursor, and to undo " +
                "it if you change your mind.\n\n" +
                "It reads the contents of a field only at the moment you insert into " +
                "it, and only in memory. Field text is never stored, logged, or sent " +
                "anywhere — not to the gateway, and not to us. The bubble stays " +
                "hidden in password and payment fields, on system permission " +
                "screens, and in any app you exclude.",
            style = MaterialTheme.typography.bodyMedium,
        )
        if (accepted) {
            Text(
                "You accepted this on this device.",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
            )
        } else {
            Button(onClick = onAccept) { Text("I understand") }
        }
    }
}

internal fun Context.openOverlaySettings() {
    startActivity(
        Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.fromParts("package", packageName, null),
        )
    )
}

internal fun Context.openAccessibilitySettings() {
    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
}

internal fun Context.openBatterySettings() {
    // The user-visible list, rather than the direct request dialog: Play treats
    // an unprompted exemption request as a policy violation.
    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
}

internal fun Context.openAppSettings() {
    startActivity(
        Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", packageName, null),
        )
    )
}
