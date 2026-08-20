package com.vocahq.vocaphone.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.settings.VocaPhoneSettings

private val SpeechModes = listOf("On this phone", "Gateway")

/**
 * Where speech is transcribed: this phone, or a gateway.
 *
 * These are opposing modes, so the control is a single-select segmented row,
 * not a switch and not a pair of cards.
 */
@Composable
fun SpeechSourceCard(
    settings: VocaPhoneSettings,
    onOpenGateway: () -> Unit,
    onLocalTranscriptionEnabled: (Boolean) -> Unit,
    onOpenModels: (() -> Unit)? = null,
    compact: Boolean = false,
) {
    val context = LocalContext.current
    val localModel = LocalModelCatalog.find(settings.localModelId)
    val copy = speechSourceCopy(
        localEnabled = settings.localTranscriptionEnabled,
        localModelName = localModel?.displayName,
        gatewayConfigured = settings.isConfigured,
        gatewayUrl = settings.gatewayUrl,
        lastEngine = settings.lastEngine,
        lastEngineReady = settings.lastEngineReady,
    )
    val localOn = copy.localSelected

    fun pick(wantLocal: Boolean) {
        val choice = speechSourceSelection(wantLocal, settings.isConfigured)
        onLocalTranscriptionEnabled(choice.localEnabled)
        if (choice.openGateway) onOpenGateway()
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (!compact) {
            Text("Speech", style = MaterialTheme.typography.titleSmall)
            Text(
                "Transcribe on this phone, or send audio to a gateway you run.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            SpeechModes.forEachIndexed { index, label ->
                val wantLocal = index == 0
                SegmentedButton(
                    selected = wantLocal == localOn,
                    onClick = { pick(wantLocal) },
                    shape = SegmentedButtonDefaults.itemShape(
                        index = index,
                        count = SpeechModes.size,
                    ),
                    label = { Text(label) },
                )
            }
        }
        Text(
            if (localOn) copy.localDetail else copy.gatewayDetail,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (compact) {
            if (!localOn) {
                TextButton(
                    onClick = onOpenGateway,
                    contentPadding = PaddingValues(0.dp),
                ) {
                    Text(if (settings.isConfigured) "Gateway settings" else "Set up a gateway")
                }
            }
            return@Column
        }
        if (localOn) {
            if (localModel != null) {
                Text(localModel.catalogMeta(), style = MaterialTheme.typography.bodySmall)
            }
            if (onOpenModels != null) {
                TextButton(
                    onClick = onOpenModels,
                    contentPadding = PaddingValues(0.dp),
                ) {
                    Text(if (localModel == null) "Download a model" else "Change model")
                }
            }
            Text(
                copy.inactiveHint,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            )
        } else {
            Text(
                copy.inactiveHint,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            )
            if (settings.isConfigured) {
                Text(
                    copy.engineLabel,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                TextButton(
                    onClick = { context.openHttpUrl(settings.gatewayUrl) },
                    contentPadding = PaddingValues(0.dp),
                ) {
                    Text("Open web dashboard")
                }
            }
            TextButton(
                onClick = onOpenGateway,
                contentPadding = PaddingValues(0.dp),
            ) {
                Text(if (settings.isConfigured) "Gateway settings" else "Set up a gateway")
            }
            TextButton(
                onClick = { context.openHttpUrl(GATEWAY_GUIDE_URL) },
                contentPadding = PaddingValues(0.dp),
            ) {
                Text("How to run a gateway")
            }
        }
    }
}
