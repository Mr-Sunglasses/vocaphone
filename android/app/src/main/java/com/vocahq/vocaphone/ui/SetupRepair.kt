package com.vocahq.vocaphone.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
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
    modifier: Modifier = Modifier,
) {
    val missing = status.remainingSteps
    if (missing.isEmpty()) return

    val context = LocalContext.current
    val requestPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }

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
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            missing.forEach { step ->
                when (step) {
                    SetupStep.MICROPHONE -> ChecklistRow(
                        title = "Microphone",
                        detail = "Records only while you are dictating.",
                        satisfied = false,
                        actionLabel = "Grant",
                        onAction = { requestPermission.launch(Manifest.permission.RECORD_AUDIO) },
                    )

                    SetupStep.NOTIFICATIONS -> ChecklistRow(
                        title = "Notifications",
                        detail = "Shows the ongoing recording notification Android requires.",
                        satisfied = false,
                        actionLabel = "Grant",
                        onAction = { requestPermission.launch(Manifest.permission.POST_NOTIFICATIONS) },
                    )

                    SetupStep.KEYBOARD -> ChecklistRow(
                        title = "VocaPhone keyboard",
                        detail = "Enable and select VocaPhone in Android's keyboard settings.",
                        satisfied = false,
                        actionLabel = "Open",
                        onAction = { ImeSetup.openSettings(context) },
                    )

                    SetupStep.GATEWAY -> ChecklistRow(
                        title = "Gateway",
                        detail = "The self-hosted VocaPhone server that transcribes your speech.",
                        satisfied = false,
                        actionLabel = "Set up",
                        onAction = onOpenGateway,
                    )
                }
            }
        }
    }
}
