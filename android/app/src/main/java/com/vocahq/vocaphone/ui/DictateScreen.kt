package com.vocahq.vocaphone.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.BuildConfig
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.TextInsertion
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import com.vocahq.vocaphone.telemetry.TelemetryInspectPayload

/**
 * In-app dictation. The transcript lands in a scratchpad the user can edit.
 */
@Composable
fun DictateScreen(
    state: DictationState,
    settings: VocaPhoneSettings,
    setup: SetupStatus,
    onStart: () -> Unit,
    onFinish: () -> Unit,
    onCancel: () -> Unit,
    onRetry: (String) -> Unit,
    onDismiss: () -> Unit,
    onOpenGateway: () -> Unit,
    onTelemetryDecision: (Boolean) -> Unit,
    telemetryInspect: () -> TelemetryInspectPayload,
    telemetryPendingCount: () -> Int,
    telemetryDeliveryStatus: () -> String,
    modifier: Modifier = Modifier,
) {
    var scratchpad by remember { mutableStateOf(TextFieldValue()) }

    // A finished in-app dictation is spliced at the scratchpad cursor.
    LaunchedEffect(state.transcript, state.phase) {
        val transcript = state.transcript
        if (transcript != null && state.phase == DictationPhase.READY_TO_INSERT) {
            val text = scratchpad.text
            val selection = scratchpad.selection
            val plan = TextInsertion.plan(text, selection.start, selection.end, transcript)
            if (plan != null) {
                scratchpad = TextFieldValue(
                    text = plan.updatedText,
                    selection = androidx.compose.ui.text.TextRange(plan.cursor),
                )
            }
            onDismiss()
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(SectionSpacing),
    ) {
        // Guided setup asks once, at its end -- but only people who go through
        // setup ever reach that screen. Everyone upgrading from an earlier beta
        // already has onboardingComplete set, so SetupScreen never renders for
        // them and they would never be asked at all. Asking here covers them,
        // and disappears for good either way once answered.
        if (BuildConfig.TELEMETRY && settings.onboardingComplete && !settings.telemetryAsked) {
            UsageReportingSetupCard(
                onDecision = onTelemetryDecision,
                inspect = telemetryInspect,
                pendingCount = telemetryPendingCount,
                deliveryStatus = telemetryDeliveryStatus,
            )
        }

        Section(
            title = "Dictate",
            supporting = listOf(
                settings.language.displayName,
                settings.style.displayName,
                if (settings.localTranscriptionEnabled) {
                    LocalModelCatalog.find(settings.localModelId)?.displayName ?: "On this phone"
                } else {
                    settings.gatewayUrl.ifEmpty { "No gateway" }
                },
            ).joinToString(" · "),
        ) {
            Text(state.statusText, style = MaterialTheme.typography.bodyLarge)

            if (state.isRecording) {
                LinearProgressIndicator(
                    progress = { state.level.coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "${state.recordedMillis / 1000}s" +
                        (state.inputRouteLabel?.let { " · $it" } ?: "") +
                        (if (state.streaming) " · streaming" else " · batch upload"),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (state.approachingLimit) {
                    Text(
                        "One minute left before the five-minute limit stops this recording.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                if (state.partialTranscript.isNotEmpty()) {
                    Text(
                        state.partialTranscript,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (state.phase == DictationPhase.FAILED) {
                Text(
                    state.failure?.message.orEmpty(),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                when {
                    state.isRecording -> {
                        PrimaryButton("Finish", onClick = onFinish, modifier = Modifier.weight(1f))
                        SecondaryButton("Cancel", onClick = onCancel, modifier = Modifier.weight(1f))
                    }

                    state.phase.isBusy ->
                        SecondaryButton("Cancel", onClick = onCancel, modifier = Modifier.weight(1f))

                    state.canRetry -> {
                        PrimaryButton(
                            text = "Retry",
                            onClick = { state.sessionId?.let { onRetry(it.toString()) } },
                            modifier = Modifier.weight(1f),
                        )
                        SecondaryButton("Dismiss", onClick = onDismiss, modifier = Modifier.weight(1f))
                    }

                    else -> PrimaryButton(
                        text = "Start dictation",
                        onClick = onStart,
                        enabled = setup.isReadyToDictate,
                        modifier = Modifier.weight(1f),
                    )
                }
            }

            if (!setup.isReadyToDictate) {
                Text(
                    "Dictation is paused. See below.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }

        // Directly under the disabled button rather than at the foot of the
        // screen: this is the answer to why the button will not press.
        SetupRepair(
            status = setup,
            onOpenGateway = onOpenGateway,
        )

        Section(
            title = "Scratchpad",
            supporting = "Transcripts are inserted at the cursor. Nothing here is uploaded.",
        ) {
            OutlinedTextField(
                value = scratchpad,
                onValueChange = { scratchpad = it },
                modifier = Modifier.fillMaxWidth().height(220.dp),
                label = { Text("Your text") },
            )
            SecondaryButton(
                text = "Clear",
                onClick = { scratchpad = TextFieldValue() },
                enabled = scratchpad.text.isNotEmpty(),
            )
        }
    }
}
