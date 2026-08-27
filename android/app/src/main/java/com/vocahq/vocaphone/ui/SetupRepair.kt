package com.vocahq.vocaphone.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/**
 * Shows the exact IME, permission, or gateway action that is keeping dictation
 * paused after the user returns from Android settings.
 */
@Composable
fun SetupRepair(
    status: SetupStatus,
    onOpenGateway: () -> Unit,
    onRefreshSetup: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // Launcher must register unconditionally; early-return after the last
    // remaining step would otherwise skip remember* and crash composition.
    val context = LocalContext.current
    val activity = context.findActivity()
    val requestPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { onRefreshSetup() }

    val missing = status.remainingSteps
    if (missing.isEmpty()) return
    val nextStep = missing.first()

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Notice(tone = NoticeTone.Attention) {
            Text(
                if (missing.size == 1) "One thing needs fixing" else "${missing.size} things need fixing",
                style = MaterialTheme.typography.titleSmall,
            )
            Text(
                "Dictation stays paused until these are back.",
                style = MaterialTheme.typography.bodyMedium,
            )
            missing.forEach { step ->
                val spotlight = step == nextStep
                when (step) {
                    SetupStep.MICROPHONE -> SetupPermissionRow(
                        step = step,
                        permission = Manifest.permission.RECORD_AUDIO,
                        satisfied = false,
                        nextStep = nextStep,
                        recentlyReady = emptySet(),
                        activity = activity,
                        requestPermission = requestPermission::launch,
                        actionColor = LocalContentColor.current,
                    )

                    SetupStep.NOTIFICATIONS -> SetupPermissionRow(
                        step = step,
                        permission = Manifest.permission.POST_NOTIFICATIONS,
                        satisfied = false,
                        nextStep = nextStep,
                        recentlyReady = emptySet(),
                        activity = activity,
                        requestPermission = requestPermission::launch,
                        actionColor = LocalContentColor.current,
                    )

                    SetupStep.KEYBOARD -> ChecklistRow(
                        title = step.label,
                        detail = SetupCopy.keyboardStatus(status.ime),
                        satisfied = false,
                        actionLabel = SetupCopy.keyboardAction(status.ime) ?: "Open",
                        onAction = {
                            if (status.ime.enabled) {
                                ImeSetup.showPicker(context)
                            } else {
                                ImeSetup.openSettings(context)
                            }
                        },
                        actionColor = LocalContentColor.current,
                        compact = !spotlight,
                    )

                    SetupStep.GATEWAY -> ChecklistRow(
                        title = "Gateway",
                        detail = "The self-hosted VocaPhone server that transcribes your speech.",
                        satisfied = false,
                        actionLabel = "Set up",
                        onAction = onOpenGateway,
                        actionColor = LocalContentColor.current,
                        compact = !spotlight,
                    )
                }
            }
        }
    }
}
