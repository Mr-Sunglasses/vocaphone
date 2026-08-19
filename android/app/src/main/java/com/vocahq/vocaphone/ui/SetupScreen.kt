package com.vocahq.vocaphone.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.BuildConfig
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.settings.VocaPhoneSettings

internal object SetupCopy {
    /** Vector mark. Adaptive mipmaps crash painterResource. */
    val LOGO = R.drawable.ic_vocaphone_logo
    const val TITLE = "Set up VocaPhone"
    const val INTRO = "Turn on the keyboard, allow the microphone, then download a model."
    const val START = "Start dictating"

    fun keyboardStatus(status: ImeSetupStatus): String = when {
        status.selected -> "VocaPhone is the selected keyboard."
        status.enabled -> "Choose VocaPhone from the keyboard list."
        else -> "Turn on the VocaPhone keyboard."
    }

    fun keyboardAction(status: ImeSetupStatus): String? = when {
        status.selected -> null
        status.enabled -> "Choose VocaPhone keyboard"
        else -> "Enable keyboard"
    }
}

/**
 * Guided setup for the IME path. Short enough to finish without scrolling
 * past a catalog.
 */
@Composable
fun SetupScreen(
    status: SetupStatus,
    settings: VocaPhoneSettings,
    localModels: LocalModelState,
    onOpenGateway: () -> Unit,
    onLocalTranscriptionEnabled: (Boolean) -> Unit,
    onLocalModel: (LocalModelDescriptor) -> Unit,
    onDownloadLocalModel: (LocalModelDescriptor) -> Unit,
    onDownloadAndUseLocalModel: (LocalModelDescriptor) -> Unit,
    onCancelLocalModelDownload: () -> Unit,
    onTelemetryDecision: (Boolean) -> Unit,
    telemetryPayload: () -> String,
    telemetryPendingCount: () -> Int,
    telemetryDeliveryStatus: () -> String,
    onFinish: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val requestPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }

    Column(modifier = modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(SectionSpacing),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Image(
                    painter = painterResource(SetupCopy.LOGO),
                    contentDescription = "VocaPhone",
                    modifier = Modifier.size(56.dp),
                )
                Text(SetupCopy.TITLE, style = MaterialTheme.typography.headlineSmall)
                Text(
                    SetupCopy.INTRO,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                SetupProgress(status)
            }

            ImeSetupCard(status.ime)

            Section("Permissions") {
                ChecklistRow(
                    title = "Microphone",
                    detail = "Only while you dictate.",
                    satisfied = status.microphone,
                    actionLabel = "Grant",
                    onAction = { requestPermission.launch(Manifest.permission.RECORD_AUDIO) },
                )
                ChecklistRow(
                    title = "Notifications",
                    detail = "Shown while you record.",
                    satisfied = status.notifications,
                    actionLabel = "Grant",
                    onAction = { requestPermission.launch(Manifest.permission.POST_NOTIFICATIONS) },
                )
            }

            Section("Speech") {
                SpeechSourceCard(
                    settings = settings,
                    compact = true,
                    onOpenGateway = onOpenGateway,
                    onLocalTranscriptionEnabled = onLocalTranscriptionEnabled,
                )
                if (settings.localTranscriptionEnabled) {
                    LocalModelPicker(
                        state = localModels,
                        selectedModelId = settings.localModelId,
                        compact = true,
                        onSelect = onLocalModel,
                        onDownload = onDownloadLocalModel,
                        onDownloadAndUse = onDownloadAndUseLocalModel,
                        onCancelDownload = onCancelLocalModelDownload,
                    )
                }
            }

            // Last, and only once the checklist is done: asking for usage reporting
            // before the user has a working transcript is asking a favour of someone
            // still deciding whether the app is worth their time.
            //
            // The BuildConfig check is repeated here even though the card checks it
            // too, because the payload view below is a separate call. Without it R8
            // keeps that composable — and the ingest path string inside it — in the
            // F-Droid APK, where nothing can ever reach it.
            if (BuildConfig.TELEMETRY && status.isReadyToDictate && !settings.telemetryAsked) {
                var showingPayload by remember { mutableStateOf(false) }
                UsageReportingSetupCard(
                    onDecision = onTelemetryDecision,
                    onSeePayload = { showingPayload = !showingPayload },
                )
                if (showingPayload) {
                    PendingPayloadView(
                        payload = telemetryPayload(),
                        pendingCount = telemetryPendingCount(),
                        deliveryStatus = telemetryDeliveryStatus(),
                    )
                }
            }
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            PrimaryButton(
                text = SetupCopy.START,
                onClick = onFinish,
                enabled = status.isReadyToDictate,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** Setup handoff for enabling and selecting the system keyboard. */
@Composable
internal fun ImeSetupCard(status: ImeSetupStatus, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val action = SetupCopy.keyboardAction(status)
    Notice(modifier = modifier) {
        Text("VocaPhone keyboard", style = MaterialTheme.typography.titleSmall)
        Text(
            SetupCopy.keyboardStatus(status),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
        )
        if (action != null) {
            SecondaryButton(
                text = action,
                onClick = {
                    if (status.enabled) {
                        ImeSetup.showPicker(context)
                    } else {
                        ImeSetup.openSettings(context)
                    }
                },
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
        if (status.remainingLabels.isNotEmpty()) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                status.remainingLabels.forEach { label ->
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        shape = MaterialTheme.shapes.small,
                    ) {
                        Text(
                            label,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                        )
                    }
                }
            }
        }
    }
}
