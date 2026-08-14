package com.vocahq.vocaphone.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelState

/**
 * The on-device model list, shared by setup and settings.
 *
 * Recommended and installed models stay on screen. Everything else is reached
 * through search and filters rather than a raw dump or a hidden catalog.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LocalModelPicker(
    state: LocalModelState,
    selectedModelId: String,
    onSelect: (LocalModelDescriptor) -> Unit,
    onDownload: (LocalModelDescriptor) -> Unit,
    onDownloadAndUse: (LocalModelDescriptor) -> Unit = onDownload,
    onCancelDownload: () -> Unit = {},
    onDelete: ((LocalModelDescriptor) -> Unit)? = null,
    usingGateway: Boolean = false,
) {
    val usable = remember(state.totalRamGB) {
        LocalModelCatalog.usableOnDevice(state.totalRamGB).sortedBy { it.sizeBytes }
    }
    val recommended = remember(state.totalRamGB) {
        LocalModelCatalog.recommended(state.totalRamGB)
    }
    val selectedModel = usable.firstOrNull { it.id == selectedModelId }

    var query by remember { mutableStateOf("") }
    var engineFilter by remember { mutableStateOf(ModelEngineFilter.ALL) }
    var sizeFilter by remember { mutableStateOf(ModelSizeFilter.ANY) }
    var languageFilter by remember { mutableStateOf(ModelLanguageFilter.ANY) }
    var inspecting by remember { mutableStateOf<LocalModelDescriptor?>(null) }

    val filtered = remember(usable, query, engineFilter, sizeFilter, languageFilter) {
        filterModelCatalog(usable, query, engineFilter, sizeFilter, languageFilter)
    }
    val recommendedVisible = filtered.any { it.id == recommended.id }
    val installedModels = filtered.filter {
        it.id in state.downloaded && !(recommendedVisible && it.id == recommended.id)
    }
    val availableModels = filtered.filter {
        it.id !in state.downloaded && !(recommendedVisible && it.id == recommended.id)
    }
    val busy = state.downloading != null || state.preparing != null

    if (usable.isEmpty()) {
        Text(
            "No on-device model fits this phone yet.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        return
    }

    if (usingGateway) {
        Text(
            "Speech is going through your gateway. Using a model here switches to this phone.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }

    if (state.downloading != null || state.preparing != null) {
        ModelBusyBanner(state = state, onCancelDownload = onCancelDownload)
    }

    if (selectedModel != null && selectedModel.sizeBytes > recommended.sizeBytes) {
        OversizedModelNotice(
            recommended = recommended,
            installed = recommended.id in state.downloaded,
            busy = busy,
            onSelect = onSelect,
            onDownloadAndUse = onDownloadAndUse,
        )
    }

    if (recommendedVisible) {
        RecommendedModelCard(
            model = recommended,
            state = state,
            selected = selectedModelId == recommended.id,
            busy = busy,
            onSelect = onSelect,
            onDownloadAndUse = onDownloadAndUse,
            onCancelDownload = onCancelDownload,
        )
    }

    OutlinedTextField(
        value = query,
        onValueChange = { query = it },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
        label = { Text("Find a model") },
        placeholder = { Text("Name, language, or engine") },
    )
    ChipChoiceRow(
        options = ModelEngineFilter.entries,
        selected = engineFilter,
        label = { it.displayName },
        onSelect = { engineFilter = it },
    )
    ChipChoiceRow(
        options = ModelSizeFilter.entries,
        selected = sizeFilter,
        label = { it.displayName },
        onSelect = { sizeFilter = it },
    )
    ChipChoiceRow(
        options = ModelLanguageFilter.entries,
        selected = languageFilter,
        label = { it.displayName },
        onSelect = { languageFilter = it },
    )

    if (installedModels.isNotEmpty()) {
        ModelSectionHeading("Installed")
        ModelTileGrid(
            models = installedModels,
            state = state,
            selectedModelId = selectedModelId,
            onInspect = { inspecting = it },
        )
    }

    ModelSectionHeading(
        if (availableModels.isEmpty()) "Catalog" else "Catalog (${availableModels.size})",
    )
    when {
        availableModels.isEmpty() && filtered.isEmpty() -> Text(
            "No models match. Clear the search or a filter.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        availableModels.isEmpty() -> Text(
            "Every matching model is already installed.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        else -> ModelTileGrid(
            models = availableModels,
            state = state,
            selectedModelId = selectedModelId,
            onInspect = { inspecting = it },
        )
    }

    state.message?.let {
        Text(
            it,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }

    inspecting?.let { model ->
        ModelDetailSheet(
            model = model,
            state = state,
            selected = selectedModelId == model.id,
            recommended = model.id == recommended.id,
            busy = busy,
            onSelect = onSelect,
            onDownloadAndUse = onDownloadAndUse,
            onCancelDownload = onCancelDownload,
            onDelete = onDelete,
            onDismiss = { inspecting = null },
        )
    }
}

@Composable
private fun ModelBusyBanner(state: LocalModelState, onCancelDownload: () -> Unit) {
    FeaturedCard {
        when {
            state.preparing != null -> Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Text(
                    "Loading ${state.preparing}… Please wait.",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            state.downloading != null -> {
                val name = LocalModelCatalog.find(state.downloading)?.displayName
                    ?: state.downloading
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Downloading $name",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    TextButton(onClick = onCancelDownload) { Text("Cancel") }
                }
                LinearProgressIndicator(
                    progress = { state.progress / 100f },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "${state.progress}%",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun RecommendedModelCard(
    model: LocalModelDescriptor,
    state: LocalModelState,
    selected: Boolean,
    busy: Boolean,
    onSelect: (LocalModelDescriptor) -> Unit,
    onDownloadAndUse: (LocalModelDescriptor) -> Unit,
    onCancelDownload: () -> Unit,
) {
    FeaturedCard {
        Text("Recommended for this phone", style = MaterialTheme.typography.titleSmall)
        Text(model.displayName, style = MaterialTheme.typography.titleMedium)
        Text(
            model.catalogMeta(),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        ModelActions(
            model = model,
            state = state,
            selected = selected,
            busy = busy,
            useLabel = "Use recommended",
            downloadLabel = "Download and use",
            onSelect = onSelect,
            onDownload = onDownloadAndUse,
            onCancelDownload = onCancelDownload,
            onDelete = null,
        )
    }
}

@Composable
private fun OversizedModelNotice(
    recommended: LocalModelDescriptor,
    installed: Boolean,
    busy: Boolean,
    onSelect: (LocalModelDescriptor) -> Unit,
    onDownloadAndUse: (LocalModelDescriptor) -> Unit,
) {
    Notice(tone = NoticeTone.Attention) {
        Text(
            "The selected model is larger than this phone is rated for, which can " +
                "make every dictation take much longer. ${recommended.displayName} is " +
                "the fastest good match.",
            style = MaterialTheme.typography.bodySmall,
        )
        SecondaryButton(
            text = if (installed) {
                "Switch to ${recommended.displayName}"
            } else {
                "Download and use ${recommended.displayName}"
            },
            onClick = {
                if (installed) onSelect(recommended) else onDownloadAndUse(recommended)
            },
            enabled = !busy,
            modifier = Modifier.fillMaxWidth(),
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
private fun ModelTileGrid(
    models: List<LocalModelDescriptor>,
    state: LocalModelState,
    selectedModelId: String,
    onInspect: (LocalModelDescriptor) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        models.chunked(2).forEach { row ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(IntrinsicSize.Min),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                row.forEach { model ->
                    ModelTile(
                        model = model,
                        selected = model.id == selectedModelId,
                        installed = model.id in state.downloaded,
                        downloading = state.downloading == model.id,
                        progress = state.progress,
                        onClick = { onInspect(model) },
                        modifier = Modifier.weight(1f),
                    )
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun ModelTile(
    model: LocalModelDescriptor,
    selected: Boolean,
    installed: Boolean,
    downloading: Boolean,
    progress: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    Surface(
        modifier = modifier.fillMaxHeight(),
        onClick = onClick,
        color = if (selected) colors.primaryContainer else colors.surfaceContainerLow,
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
                model.displayName,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${model.sizeLabel} · ${model.engineLabel()}",
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant,
            )
            Spacer(Modifier.weight(1f))
            Text(
                when {
                    downloading -> "Downloading $progress%"
                    selected -> "In use"
                    installed -> "Installed"
                    else -> model.languages
                },
                style = MaterialTheme.typography.labelSmall,
                color = if (selected || downloading) colors.primary else colors.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelDetailSheet(
    model: LocalModelDescriptor,
    state: LocalModelState,
    selected: Boolean,
    recommended: Boolean,
    busy: Boolean,
    onSelect: (LocalModelDescriptor) -> Unit,
    onDownloadAndUse: (LocalModelDescriptor) -> Unit,
    onCancelDownload: () -> Unit,
    onDelete: ((LocalModelDescriptor) -> Unit)?,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(model.displayName, style = MaterialTheme.typography.titleLarge)
            if (recommended) {
                Text(
                    "Recommended for this phone",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            Text(
                model.catalogMeta(),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                "Needs at least ${model.minimumRamGB} GB of RAM.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            ModelActions(
                model = model,
                state = state,
                selected = selected,
                busy = busy,
                useLabel = "Use this model",
                downloadLabel = "Download and use",
                onSelect = onSelect,
                onDownload = onDownloadAndUse,
                onCancelDownload = onCancelDownload,
                onDelete = onDelete,
            )
        }
    }
}

@Composable
private fun ModelActions(
    model: LocalModelDescriptor,
    state: LocalModelState,
    selected: Boolean,
    busy: Boolean,
    useLabel: String,
    downloadLabel: String,
    onSelect: (LocalModelDescriptor) -> Unit,
    onDownload: (LocalModelDescriptor) -> Unit,
    onCancelDownload: () -> Unit,
    onDelete: ((LocalModelDescriptor) -> Unit)?,
) {
    when {
        state.preparing == model.displayName -> Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            Text(
                "Loading model… Please wait.",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
            )
        }
        state.downloading == model.id -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
                TextButton(onClick = onCancelDownload) { Text("Cancel") }
            }
            LinearProgressIndicator(
                progress = { state.progress / 100f },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        model.id !in state.downloaded -> PrimaryButton(
            text = downloadLabel,
            onClick = { onDownload(model) },
            enabled = !busy,
            modifier = Modifier.fillMaxWidth(),
        )
        selected -> {
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
                    "In use",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            if (onDelete != null) {
                TextButton(
                    onClick = { onDelete(model) },
                    modifier = Modifier,
                    colors = ButtonDefaults.textButtonColors(
                        contentColor = MaterialTheme.colorScheme.error,
                    ),
                    contentPadding = PaddingValues(horizontal = 0.dp),
                ) {
                    Text("Delete downloaded model")
                }
            }
        }
        else -> {
            SecondaryButton(
                text = useLabel,
                onClick = { onSelect(model) },
                enabled = state.preparing == null,
                modifier = Modifier.fillMaxWidth(),
            )
            if (onDelete != null) {
                TextButton(
                    onClick = { onDelete(model) },
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
