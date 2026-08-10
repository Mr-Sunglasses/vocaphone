package com.vocahq.vocaphone.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelState

/**
 * The on-device model list, shared by setup and settings.
 *
 * The catalog is deliberately large, so this shows only what the phone can
 * actually run. Installed models and downloadable models stay in separate
 * sections so the models ready to use are easy to find.
 */
@Composable
fun LocalModelPicker(
    state: LocalModelState,
    selectedModelId: String,
    onSelect: (LocalModelDescriptor) -> Unit,
    onDownload: (LocalModelDescriptor) -> Unit,
    onCancelDownload: () -> Unit = {},
    onDelete: ((LocalModelDescriptor) -> Unit)? = null,
) {
    val usable = remember(state.totalRamGB) {
        LocalModelCatalog.usableOnDevice(state.totalRamGB).sortedBy { it.sizeBytes }
    }
    val recommended = remember(state.totalRamGB) {
        LocalModelCatalog.recommended(state.totalRamGB)
    }
    val installedModels = usable.filter { it.id in state.downloaded }
    val availableModels = usable.filter { it.id !in state.downloaded }
    var availableModelsExpanded by remember { mutableStateOf(false) }

    if (usable.isEmpty()) {
        Text(
            "No on-device model fits this phone yet.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        return
    }

    if (installedModels.isNotEmpty()) {
        ModelSectionHeading("Installed models")
        ModelRows(
            models = installedModels,
            state = state,
            selectedModelId = selectedModelId,
            recommendedModelId = recommended.id,
            onSelect = onSelect,
            onDownload = onDownload,
            onCancelDownload = onCancelDownload,
            onDelete = onDelete,
        )
    }

    if (availableModels.isEmpty()) {
        ModelSectionHeading("Available models")
        Text(
            "All compatible models are installed.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    } else {
        ModelSectionToggle(
            title = "Available models",
            count = availableModels.size,
            expanded = availableModelsExpanded,
            onToggle = { availableModelsExpanded = !availableModelsExpanded },
        )
        if (availableModelsExpanded) {
            ModelRows(
                models = availableModels,
                state = state,
                selectedModelId = selectedModelId,
                recommendedModelId = recommended.id,
                onSelect = onSelect,
                onDownload = onDownload,
                onCancelDownload = onCancelDownload,
                onDelete = onDelete,
            )
        } else {
            Text(
                "${availableModels.size} compatible model${if (availableModels.size == 1) "" else "s"} available to download.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }

    state.message?.let {
        Text(
            it,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ModelSectionHeading(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 4.dp),
    )
}

@Composable
private fun ModelSectionToggle(
    title: String,
    count: Int,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "$title ($count)",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
        )
        TextButton(
            onClick = onToggle,
            contentPadding = PaddingValues(horizontal = 0.dp),
        ) {
            Text(if (expanded) "Hide" else "Show")
        }
    }
}

@Composable
private fun ModelRows(
    models: List<LocalModelDescriptor>,
    state: LocalModelState,
    selectedModelId: String,
    recommendedModelId: String,
    onSelect: (LocalModelDescriptor) -> Unit,
    onDownload: (LocalModelDescriptor) -> Unit,
    onCancelDownload: () -> Unit,
    onDelete: ((LocalModelDescriptor) -> Unit)?,
) {
    models.forEachIndexed { index, model ->
        ModelRow(
            model = model,
            state = state,
            selectedModelId = selectedModelId,
            recommendedModelId = recommendedModelId,
            onSelect = onSelect,
            onDownload = onDownload,
            onCancelDownload = onCancelDownload,
            onDelete = onDelete,
        )
        if (index < models.lastIndex) HorizontalDivider()
    }
}

@Composable
private fun ModelRow(
    model: LocalModelDescriptor,
    state: LocalModelState,
    selectedModelId: String,
    recommendedModelId: String,
    onSelect: (LocalModelDescriptor) -> Unit,
    onDownload: (LocalModelDescriptor) -> Unit,
    onCancelDownload: () -> Unit,
    onDelete: ((LocalModelDescriptor) -> Unit)?,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(model.displayName, style = MaterialTheme.typography.bodyLarge)
            Text(
                buildString {
                    append(model.sizeLabel)
                    append(" · ")
                    append(model.languages)
                    if (model.id == recommendedModelId) append(" · recommended")
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        when {
            state.downloading == model.id -> {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "Downloading",
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("${state.progress}%")
                            TextButton(onClick = onCancelDownload) { Text("Cancel") }
                        }
                    }
                    LinearProgressIndicator(
                        progress = { state.progress / 100f },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            model.id !in state.downloaded -> SecondaryButton(
                text = "Download",
                onClick = { onDownload(model) },
                enabled = state.downloading == null,
                modifier = Modifier.fillMaxWidth(),
            )
            else -> {
                if (selectedModelId == model.id) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(
                            painter = painterResource(R.drawable.ic_step_done),
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                        )
                        Text(
                            "Selected model",
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                } else {
                    SecondaryButton(
                        text = "Use this model",
                        onClick = { onSelect(model) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (onDelete != null) {
                    TextButton(
                        onClick = { onDelete(model) },
                        modifier = Modifier.align(Alignment.Start),
                        colors = ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme.colorScheme.error,
                        ),
                        contentPadding = PaddingValues(horizontal = 0.dp),
                    ) {
                        Text("Delete downloaded model")
                    }
                }
            }
        }
    }
}
