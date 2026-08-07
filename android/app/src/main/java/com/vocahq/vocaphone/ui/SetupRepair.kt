package com.vocahq.vocaphone.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/**
 * The way back when a step that was satisfied once stops being satisfied.
 *
 * Force stop is the usual cause and by far the least obvious: Android drops an
 * app out of `ENABLED_ACCESSIBILITY_SERVICES` whenever the user force stops it,
 * and no manifest flag or API opts out of that. Onboarding has long since
 * completed by then, so the checklist that would have explained any of this is
 * gated off for good — without this card the bubble simply stops appearing and
 * nothing on screen says why, or what to do about it.
 *
 * It deliberately repeats the setup screen's actions rather than sending the
 * user back into onboarding: only one step is usually broken, and re-running a
 * six-step wizard to repair it reads as though the app has forgotten them.
 *
 * The `when` below is exhaustive on purpose: a new [SetupStep] has to be given a
 * repair route here before this compiles, rather than silently going missing.
 */
@Composable
fun SetupRepairCard(
    status: SetupStatus,
    onOpenGateway: () -> Unit,
    onAcceptDisclosure: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val missing = status.remainingSteps
    if (missing.isEmpty()) return

    // Consent, not a checkbox: the disclosure gets its own full card below, so
    // repairing it cannot become a one-tap accept next to unrelated rows. Held
    // out of the checklist here as well, so a disclosure-only repair does not
    // render a headed card with nothing inside it.
    val rows = missing.filterNot { it == SetupStep.DISCLOSURE }

    val context = LocalContext.current
    val requestPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (rows.isNotEmpty()) {
            SectionCard(
                title = if (missing.size == 1) {
                    "One thing needs fixing"
                } else {
                    "${missing.size} things need fixing"
                },
                supporting = "Dictation stays paused until these are back.",
            ) {
                rows.forEach { step ->
                    when (step) {
                        // Filtered out above; kept so the `when` stays exhaustive.
                        SetupStep.DISCLOSURE -> Unit

                        SetupStep.MICROPHONE -> ChecklistRow(
                            title = "Microphone",
                            detail = "Records only while you are dictating.",
                            satisfied = false,
                            actionLabel = "Grant",
                            onAction = {
                                requestPermission.launch(Manifest.permission.RECORD_AUDIO)
                            },
                        )

                        SetupStep.NOTIFICATIONS -> ChecklistRow(
                            title = "Notifications",
                            detail = "Shows the ongoing recording notification Android requires.",
                            satisfied = false,
                            actionLabel = "Grant",
                            onAction = {
                                requestPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                            },
                        )

                        SetupStep.OVERLAY -> ChecklistRow(
                            title = "Display over other apps",
                            detail = "Draws the dictation bubble above the app you are typing in.",
                            satisfied = false,
                            actionLabel = "Open",
                            onAction = { context.openOverlaySettings() },
                        )

                        SetupStep.ACCESSIBILITY -> ChecklistRow(
                            title = "Accessibility service",
                            detail = "Finds the focused field and inserts your transcript. " +
                                "Force stopping VocaPhone always switches this off — " +
                                "Android does that to every app with an accessibility " +
                                "service, and only you can switch it back on.",
                            satisfied = false,
                            actionLabel = "Open",
                            onAction = { context.openAccessibilitySettings() },
                        )

                        SetupStep.GATEWAY -> ChecklistRow(
                            title = "Gateway",
                            detail = "The self-hosted VocaPhone server that transcribes " +
                                "your speech.",
                            satisfied = false,
                            actionLabel = "Set up",
                            onAction = onOpenGateway,
                        )
                    }
                }
            }
        }

        if (SetupStep.DISCLOSURE in missing) {
            AccessibilityDisclosureCard(accepted = false, onAccept = onAcceptDisclosure)
        }

        if (status.restrictedSettingsGuidance) {
            RestrictedSettingsCard(
                onOpenAccessibilitySettings = { context.openAccessibilitySettings() },
                onOpenAppInfo = { context.openAppSettings() },
            )
        }
    }
}
