package com.vocahq.vocaphone.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.settings.VocaPhoneSettings

/**
 * One place to pick where speech is transcribed: this phone, or a gateway.
 *
 * The unused side stays visible and tappable so the choice can be flipped, but
 * its details are muted. That is what "not connected" used to try to say, and
 * failed at, when a local model was already doing the work.
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

    FeaturedCard {
        if (!compact) {
            Text("Speech", style = MaterialTheme.typography.titleSmall)
            Text(
                "Transcribe on this phone, or send audio to a gateway you run.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Max),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SourceChoiceTile(
                title = "On this phone",
                subtitle = copy.localDetail,
                selected = localOn,
                onClick = {
                    val choice = speechSourceSelection(true, settings.isConfigured)
                    onLocalTranscriptionEnabled(choice.localEnabled)
                    if (choice.openGateway) onOpenGateway()
                },
                modifier = Modifier.weight(1f).fillMaxHeight(),
            )
            SourceChoiceTile(
                title = "Gateway",
                subtitle = copy.gatewayDetail,
                selected = !localOn,
                onClick = {
                    val choice = speechSourceSelection(false, settings.isConfigured)
                    onLocalTranscriptionEnabled(choice.localEnabled)
                    if (choice.openGateway) onOpenGateway()
                },
                modifier = Modifier.weight(1f).fillMaxHeight(),
            )
        }
        if (compact) {
            if (!localOn) {
                TextButton(
                    onClick = onOpenGateway,
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
                ) {
                    Text(if (settings.isConfigured) "Gateway settings" else "Set up a gateway")
                }
            }
            return@FeaturedCard
        }
        if (localOn) {
            if (localModel != null) {
                Text(localModel.catalogMeta(), style = MaterialTheme.typography.bodySmall)
            }
            if (onOpenModels != null) {
                TextButton(
                    onClick = onOpenModels,
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
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
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
                ) {
                    Text("Open web dashboard")
                }
            }
            TextButton(
                onClick = onOpenGateway,
                contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
            ) {
                Text(if (settings.isConfigured) "Gateway settings" else "Set up a gateway")
            }
            TextButton(
                onClick = { context.openHttpUrl(GATEWAY_GUIDE_URL) },
                contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
            ) {
                Text("How to run a gateway")
            }
        }
    }
}

@Composable
private fun SourceChoiceTile(
    title: String,
    subtitle: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    Surface(
        modifier = modifier,
        onClick = onClick,
        color = if (selected) colors.primaryContainer else colors.surfaceContainerHigh,
        shape = MaterialTheme.shapes.large,
        border = if (selected) BorderStroke(1.dp, colors.primary) else null,
    ) {
        Column(
            modifier = Modifier
                .fillMaxHeight()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                color = if (selected) colors.primary else colors.onSurface,
            )
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = if (selected) {
                    colors.onSurfaceVariant
                } else {
                    colors.onSurfaceVariant.copy(alpha = 0.5f)
                },
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
