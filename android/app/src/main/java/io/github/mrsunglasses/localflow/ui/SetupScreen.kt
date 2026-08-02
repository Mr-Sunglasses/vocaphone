package io.github.mrsunglasses.localflow.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
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

        if (status.restrictedSettingsGuidance) {
            RestrictedSettingsCard(
                onOpenAccessibilitySettings = { context.openAccessibilitySettings() },
                onOpenAppInfo = { context.openAppSettings() },
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

/**
 * Shown when the accessibility switch is likely greyed out because Local Flow
 * was installed outside an app store. The "Allow restricted settings" option
 * stays hidden until the switch has actually been tried and blocked once, so
 * that has to happen before App info's overflow menu is worth opening — the
 * reverse order just lands on a menu with nothing useful in it.
 */
@Composable
fun RestrictedSettingsCard(
    onOpenAccessibilitySettings: () -> Unit,
    onOpenAppInfo: () -> Unit,
    modifier: Modifier = Modifier,
) {
    SectionCard(
        title = "Can't turn the accessibility service on?",
        modifier = modifier,
    ) {
        Text(
            "Android blocks apps installed outside an app store from using " +
                "accessibility access, so the switch may be greyed out and " +
                "labelled \"Restricted setting\". Local Flow cannot lift that " +
                "itself — only you can, and the fix only appears after you've " +
                "been blocked once:\n\n" +
                "1. Open Accessibility settings below and try turning Local " +
                "Flow on. It will refuse and show a \"Restricted setting\" " +
                "message — that's expected, and it's what unlocks the next " +
                "step.\n" +
                "2. Open App info. Tap the ⋮ menu in the top-right corner and " +
                "choose \"Allow restricted settings\". On some Samsung phones " +
                "it appears as its own row on this page instead, without " +
                "needing the menu.\n" +
                "3. Confirm with your PIN, pattern or fingerprint.\n" +
                "4. Come back to Accessibility settings and turn Local Flow " +
                "on — it will work this time.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = onOpenAccessibilitySettings) { Text("1. Accessibility") }
            Button(onClick = onOpenAppInfo) { Text("2. App info") }
        }
        Text(
            "On Samsung phones running One UI 8.5, \"Allow restricted " +
                "settings\" is currently missing from App info entirely for " +
                "every sideloaded app — a Samsung bug, not something Local " +
                "Flow can work around from here. If that's what you're " +
                "seeing, granting accessibility from a computer over adb is " +
                "the only way through right now; see the project's GitHub " +
                "releases page for the exact command.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
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
