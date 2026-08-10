package com.vocahq.vocaphone.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.settings.VocaPhoneSettings

/**
 * Guided setup for the IME path. VocaPhone does not request accessibility or
 * overlay access; the keyboard inserts through Android's InputConnection.
 */
@Composable
fun SetupScreen(
    status: SetupStatus,
    settings: VocaPhoneSettings,
    localModels: LocalModelState,
    onOpenGateway: () -> Unit,
    onLocalModel: (LocalModelDescriptor) -> Unit,
    onDownloadLocalModel: (LocalModelDescriptor) -> Unit,
    onCancelLocalModelDownload: () -> Unit,
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
        verticalArrangement = Arrangement.spacedBy(SectionSpacing),
    ) {
        Text("Set up VocaPhone", style = MaterialTheme.typography.headlineSmall)
        Text(
            "VocaPhone is a voice keyboard. Turn it on and select it when you want " +
                "to dictate into any text field. Choose either your self-hosted " +
                "gateway or an on-device speech-to-text model.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        SetupProgress(status)

        ImeSetupCard(status.ime)

        Section("Permissions") {
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
        }

        Section("Transcription source", supporting = "A gateway or a verified local model.") {
            ChecklistRow(
                title = if (settings.localTranscriptionEnabled) "On-device model" else "Address and token",
                detail = if (status.gatewayConfigured) {
                    if (settings.localTranscriptionEnabled) {
                        "On device: ${settings.localModelId}"
                    } else {
                        settings.gatewayUrl
                    }
                } else {
                    "A LAN, Tailscale or HTTPS gateway you control."
                },
                satisfied = status.gatewayConfigured,
                actionLabel = "Set up",
                onAction = onOpenGateway,
            )
            if (status.gatewayConfigured) {
                TextButton(onClick = onOpenGateway) { Text("Change or test gateway") }
            }
        }

        Section(
            "On-device option",
            supporting = "Download a model to dictate without a gateway. Every file is SHA-256 checked before it can load.",
        ) {
            LocalModelPicker(
                state = localModels,
                selectedModelId = settings.localModelId,
                onSelect = onLocalModel,
                onDownload = onDownloadLocalModel,
                onCancelDownload = onCancelLocalModelDownload,
            )
        }

        PrimaryButton(
            text = "Start dictating",
            onClick = onFinish,
            enabled = status.isReadyToDictate,
            modifier = Modifier.fillMaxWidth(),
        )
        if (!status.isReadyToDictate) {
            Text(
                "Still to do: " + status.remainingSteps.joinToString { it.label },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** Setup handoff for enabling and selecting the system keyboard. */
@Composable
internal fun ImeSetupCard(status: ImeSetupStatus, modifier: Modifier = Modifier) {
    val context = androidx.compose.ui.platform.LocalContext.current
    Notice(modifier = modifier) {
        Text("VocaPhone keyboard", style = MaterialTheme.typography.titleSmall)
        Text(
            "The microphone lives inside VocaPhone's keyboard. It inserts through " +
                "Android's text connection and does not read the contents of the field.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Text(
            when {
                status.selected -> "VocaPhone is the selected keyboard."
                status.enabled -> "VocaPhone is enabled. Select it from the keyboard picker."
                else -> "VocaPhone is not enabled as a keyboard yet."
            },
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
        )
        SecondaryButton(
            text = if (status.enabled) "Keyboard settings" else "Enable keyboard",
            onClick = { ImeSetup.openSettings(context) },
            modifier = Modifier.fillMaxWidth(),
        )
        if (status.enabled && !status.selected) {
            SecondaryButton(
                text = "Choose VocaPhone keyboard",
                onClick = { ImeSetup.showPicker(context) },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** How far through setup the user is, so the list has a visible end. */
@Composable
private fun SetupProgress(status: SetupStatus, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            "${status.completedStepCount} of ${status.stepCount} steps done",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        LinearProgressIndicator(
            progress = { status.completedStepCount.toFloat() / status.stepCount },
            modifier = Modifier.fillMaxWidth(),
        )
    }
}
