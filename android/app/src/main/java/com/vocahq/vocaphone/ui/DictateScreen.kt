package com.vocahq.vocaphone.ui

import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.BuildConfig
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.TextInsertion
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import com.vocahq.vocaphone.telemetry.TelemetryInspectPayload

internal object DictateCopy {
    const val DICTATE = "Dictate"
    const val CLEAR = "Clear"
    const val LANGUAGE = "Language"
    const val STYLE = "Writing style"
    const val MODEL = "Model"
    const val GATEWAY = "Gateway"
    const val NO_MODEL = "No model"
    const val HINT = "Inserted at the cursor. Nothing here is uploaded."
}

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
    onRefreshSetup: () -> Unit,
    onOpenLanguage: () -> Unit,
    onOpenStyle: () -> Unit,
    onOpenModel: () -> Unit,
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

    // Guided setup asks once, at its end -- but only people who go through
    // setup ever reach that screen. Everyone upgrading from an earlier beta
    // already has onboardingComplete set, so SetupScreen never renders for
    // them and they would never be asked at all. Asking here covers them, in
    // the same dialog rather than a card in this column: the column does not
    // scroll, so a card that tall hid both answers off the bottom of the phone.
    if (BuildConfig.TELEMETRY && settings.onboardingComplete && !settings.telemetryAsked) {
        UsageReportingDialog(
            onDecision = onTelemetryDecision,
            inspect = telemetryInspect,
            pendingCount = telemetryPendingCount,
            deliveryStatus = telemetryDeliveryStatus,
        )
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .wrapContentWidth(Alignment.CenterHorizontally)
            .widthIn(max = AppContentMaxWidth)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        ) {
            // Keep the scratchpad large on an ordinary phone, but let the whole
            // content region scroll when landscape, setup repair, status text,
            // or accessibility text would otherwise push actions off-screen.
            val scratchpadHeight = (maxHeight - 64.dp).coerceAtLeast(180.dp)
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    DictateAssistChip(
                        icon = R.drawable.ic_language,
                        label = settings.effectiveLanguage.displayName,
                        contentDescription = "${DictateCopy.LANGUAGE}, ${settings.effectiveLanguage.displayName}",
                        onClick = onOpenLanguage,
                    )
                    DictateAssistChip(
                        icon = R.drawable.ic_style,
                        label = settings.style.displayName,
                        contentDescription = "${DictateCopy.STYLE}, ${settings.style.displayName}",
                        onClick = onOpenStyle,
                    )
                    val modelLabel = dictateModelChipLabel(settings)
                    DictateAssistChip(
                        icon = if (settings.localTranscriptionEnabled) {
                            R.drawable.ic_models
                        } else {
                            R.drawable.ic_connection
                        },
                        label = compactModelChipLabel(modelLabel),
                        contentDescription = "${DictateCopy.MODEL}, $modelLabel",
                        onClick = onOpenModel,
                    )
                }

                if (
                    showDictateStatus(state.phase) ||
                    state.isRecording ||
                    state.phase == DictationPhase.FAILED
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (showDictateStatus(state.phase)) {
                            Text(state.statusText, style = MaterialTheme.typography.bodyLarge)
                        }
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
                    }
                }

                SetupRepair(
                    status = setup,
                    onOpenGateway = onOpenGateway,
                    onRefreshSetup = onRefreshSetup,
                )

                val fieldColors = TextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                    disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    disabledIndicatorColor = Color.Transparent,
                )
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(scratchpadHeight),
                ) {
                    TextField(
                        value = scratchpad,
                        onValueChange = { scratchpad = it },
                        modifier = Modifier.fillMaxSize(),
                        placeholder = if (showScratchpadHint(scratchpad.text, state.phase)) {
                            {
                                Text(
                                    DictateCopy.HINT,
                                    style = MaterialTheme.typography.bodyMedium,
                                )
                            }
                        } else {
                            null
                        },
                        shape = MaterialTheme.shapes.large,
                        colors = fieldColors,
                    )
                    if (scratchpad.text.isNotEmpty()) {
                        FilledTonalIconButton(
                            onClick = { scratchpad = TextFieldValue() },
                            modifier = Modifier
                                .align(Alignment.BottomCenter)
                                .padding(bottom = 12.dp),
                        ) {
                            Icon(
                                painter = painterResource(R.drawable.ic_delete),
                                contentDescription = DictateCopy.CLEAR,
                            )
                        }
                    }
                }
            }
        }

        DictateActionRow(
            state = state,
            setup = setup,
            onStart = onStart,
            onFinish = onFinish,
            onCancel = onCancel,
            onRetry = onRetry,
            onDismiss = onDismiss,
        )
    }
}

@Composable
private fun DictateActionRow(
    state: DictationState,
    setup: SetupStatus,
    onStart: () -> Unit,
    onFinish: () -> Unit,
    onCancel: () -> Unit,
    onRetry: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    when {
        state.isRecording -> ResponsiveActionRow(
            leading = { item -> SecondaryButton("Cancel", onClick = onCancel, modifier = item) },
            trailing = { item -> PrimaryButton("Finish", onClick = onFinish, modifier = item) },
            trailingWeight = 2f,
        )
        state.phase.isBusy -> SecondaryButton(
            "Cancel",
            onClick = onCancel,
            modifier = Modifier.fillMaxWidth(),
        )
        state.canRetry -> ResponsiveActionRow(
            leading = { item -> SecondaryButton("Dismiss", onClick = onDismiss, modifier = item) },
            trailing = { item ->
                PrimaryButton(
                    text = "Retry",
                    onClick = { state.sessionId?.let { onRetry(it.toString()) } },
                    modifier = item,
                )
            },
            trailingWeight = 2f,
        )
        else -> PrimaryButton(
            text = DictateCopy.DICTATE,
            onClick = onStart,
            enabled = setup.isReadyToDictate,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun DictateAssistChip(
    @DrawableRes icon: Int,
    label: String,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    AssistChip(
        onClick = onClick,
        modifier = modifier.semantics { this.contentDescription = contentDescription },
        label = {
            Text(
                text = label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        leadingIcon = {
            Icon(
                painter = painterResource(icon),
                contentDescription = null,
                modifier = Modifier.size(18.dp),
            )
        },
        border = AssistChipDefaults.assistChipBorder(
            enabled = true,
            borderColor = Color.Transparent,
            disabledBorderColor = Color.Transparent,
        ),
        colors = AssistChipDefaults.assistChipColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            labelColor = MaterialTheme.colorScheme.onSurface,
            leadingIconContentColor = MaterialTheme.colorScheme.onSurfaceVariant,
        ),
    )
}

internal fun dictateModelChipLabel(settings: VocaPhoneSettings): String =
    if (settings.localTranscriptionEnabled) {
        LocalModelCatalog.find(settings.localModelId)?.displayName ?: DictateCopy.NO_MODEL
    } else {
        DictateCopy.GATEWAY
    }

/** Language already has its own chip, so drop a trailing English from the model. */
internal fun compactModelChipLabel(label: String): String = label.removeSuffix(" English")

internal fun showDictateStatus(phase: DictationPhase): Boolean =
    phase != DictationPhase.IDLE &&
        phase != DictationPhase.FAILED &&
        phase != DictationPhase.PERMISSION_REPAIR

/** Hint lives in the pad and leaves as soon as there is text or a recording. */
internal fun showScratchpadHint(text: String, phase: DictationPhase): Boolean =
    text.isEmpty() && !phase.isBusy
