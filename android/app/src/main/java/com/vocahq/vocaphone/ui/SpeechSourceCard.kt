package com.vocahq.vocaphone.ui

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.settings.VocaPhoneSettings

// Short enough for one line at a large font. "On this phone" wrapped at 1.5x,
// and the taller half pushed the two segments out of line.
private val SpeechModes = listOf("This phone", "Gateway")

/**
 * Where speech is transcribed: this phone, or a gateway.
 *
 * These are opposing modes, so the control is a single-select segmented row,
 * not a switch and not a pair of cards. Under it is one row for the side in
 * use — the model, or the gateway — which opens that side's page. The gateway
 * address, engine, dashboard and how-to links used to be laid loose under the
 * switch; they live on the gateway page now.
 */
@Composable
fun SpeechSourceGroup(
    settings: VocaPhoneSettings,
    onOpenGateway: () -> Unit,
    onOpenModels: () -> Unit,
    onLocalTranscriptionEnabled: (Boolean) -> Unit,
) {
    val localModel = LocalModelCatalog.find(settings.localModelId)
    val localOn = settings.localTranscriptionEnabled

    fun pick(wantLocal: Boolean) {
        val choice = speechSourceSelection(wantLocal, settings.isConfigured)
        onLocalTranscriptionEnabled(choice.localEnabled)
        if (choice.openGateway) onOpenGateway()
    }

    SettingsGroup(title = "Speech") {
        SettingsGroupContent {
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
                        label = {
                            Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        },
                    )
                }
            }
        }
        SettingsDivider()
        if (localOn) {
            SettingsNavRow(
                title = "Voice model",
                supporting = localModel?.displayName ?: "Choose a model",
                icon = R.drawable.ic_models,
                onClick = onOpenModels,
            )
        } else {
            SettingsNavRow(
                title = "Gateway",
                supporting = gatewayRowSummary(
                    configured = settings.isConfigured,
                    url = settings.gatewayUrl,
                    lastEngine = settings.lastEngine,
                ),
                icon = R.drawable.ic_connection,
                onClick = onOpenGateway,
            )
        }
    }
}

/** "prod.example.com · faster-whisper:large-v3", or "Not set up". */
internal fun gatewayRowSummary(configured: Boolean, url: String, lastEngine: String): String {
    if (!configured) return "Not set up"
    val host = url.trim()
        .substringAfter("://")
        .substringBefore('/')
        .ifEmpty { url.trim() }
    return if (lastEngine.isEmpty()) host else "$host · $lastEngine"
}
