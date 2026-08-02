package com.example.localflow.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import com.example.localflow.android.core.DictationPhase
import com.example.localflow.android.core.DictationState
import com.example.localflow.android.core.TextInsertion
import com.example.localflow.android.settings.LocalFlowSettings

/**
 * In-app dictation. The transcript lands in a scratchpad the user can edit,
 * rather than in another app's field, so nothing here needs accessibility access.
 */
@Composable
fun DictateScreen(
    state: DictationState,
    settings: LocalFlowSettings,
    setup: SetupStatus,
    onStart: () -> Unit,
    onFinish: () -> Unit,
    onCancel: () -> Unit,
    onRetry: (String) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var scratchpad by remember { mutableStateOf(TextFieldValue()) }

    // A finished in-app dictation is spliced at the cursor, exactly as the bubble
    // would splice it into another app's field.
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
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        SectionCard(
            title = "Dictate",
            supporting = "${settings.language.displayName} · ${settings.style.displayName}",
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

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                when {
                    state.isRecording -> {
                        Button(onClick = onFinish) { Text("Finish") }
                        OutlinedButton(onClick = onCancel) { Text("Cancel") }
                    }

                    state.phase.isBusy -> OutlinedButton(onClick = onCancel) { Text("Cancel") }

                    state.canRetry -> {
                        Button(onClick = { state.sessionId?.let { onRetry(it.toString()) } }) {
                            Text("Retry")
                        }
                        OutlinedButton(onClick = onDismiss) { Text("Dismiss") }
                    }

                    else -> Button(onClick = onStart, enabled = setup.isReadyToDictate) {
                        Text("Start dictation")
                    }
                }
            }

            if (!setup.isReadyToDictate) {
                Text(
                    "Finish setup before dictating.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }

        SectionCard(
            title = "Scratchpad",
            supporting = "Transcripts are inserted at the cursor. Nothing here is uploaded.",
        ) {
            OutlinedTextField(
                value = scratchpad,
                onValueChange = { scratchpad = it },
                modifier = Modifier.fillMaxWidth().height(220.dp),
                label = { Text("Your text") },
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    onClick = { scratchpad = TextFieldValue() },
                    enabled = scratchpad.text.isNotEmpty(),
                ) {
                    Text("Clear")
                }
            }
        }
    }
}
