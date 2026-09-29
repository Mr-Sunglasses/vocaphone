package com.vocahq.vocaphone.ui

import android.os.SystemClock
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.local.DeviceProfile
import com.vocahq.vocaphone.local.DownloadWarning
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.local.ModelChoices
import com.vocahq.vocaphone.local.ModelGuidance
import com.vocahq.vocaphone.local.ModelGuidanceIntent
import com.vocahq.vocaphone.local.ModelGuidancePriority
import com.vocahq.vocaphone.local.ModelGuidanceResult
import com.vocahq.vocaphone.local.ModelPick
import com.vocahq.vocaphone.local.ModelPlainLanguage
import com.vocahq.vocaphone.local.byteLabel
import com.vocahq.vocaphone.local.coversLanguage
import com.vocahq.vocaphone.local.downloadSizeProgress
import com.vocahq.vocaphone.local.downloadTimeRemaining
import com.vocahq.vocaphone.local.downloadWarning
import com.vocahq.vocaphone.local.plain
import java.util.Locale

internal const val MORE_MODELS_LABEL = SetupCopy.BROWSE_MODELS

/**
 * The on-device model list, shared by setup and settings.
 *
 * Settings shows the filtered catalog on the page. Setup passes [compact] so
 * only the recommended model and any installed models stay on screen. The
 * rest opens from More models.
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
    compact: Boolean = false,
    guidanceLanguage: String = "",
    onGuidanceLanguage: (String) -> Unit = {},
    languages: List<String> = emptyList(),
    /** The selection is one the retired-model migration made; see [RetiredModelNotice]. */
    selectionFromRetiredModel: Boolean = false,
) {
    val usable = remember(state.totalRamGB) {
        LocalModelCatalog.usableOnDevice(state.totalRamGB).sortedBy { it.sizeBytes }
    }
    val profile = remember(state.totalRamGB, languages) {
        DeviceProfile.current(totalRamGB = state.totalRamGB, languages = languages)
    }
    val guidancePriority = ModelGuidancePriority.BALANCED
    var guidanceLanguageSelection by rememberSaveable(guidanceLanguage, profile.language) {
        mutableStateOf(guidanceLanguage.ifBlank { TranscriptionLanguage.AUTOMATIC.wireValue })
    }
    val guidance = remember(profile, guidanceLanguageSelection, guidancePriority) {
        ModelGuidance.recommend(
            profile,
            ModelGuidanceIntent(
                language = guidanceLanguageSelection,
                priority = guidancePriority,
            ),
        )
    }
    // The same guidance run at the other end of the trade-off. Shown as one
    // concrete swap rather than a grid: the setup card stays a single answer,
    // but the fact that a 32 MB option exists no longer lives only behind a
    // sheet most people never open.
    val lighter = remember(profile, guidanceLanguageSelection) {
        ModelGuidance.recommend(
            profile,
            ModelGuidanceIntent(
                language = guidanceLanguageSelection,
                priority = ModelGuidancePriority.LIGHTER,
            ),
        ).model
    }
    val guidanceAlternative = lighter?.takeIf { it.id != guidance.model?.id }
    val warning = guidance.model
        ?.takeIf { state.downloading == null && it.id !in state.downloaded }
        ?.let {
            downloadWarning(
                sizeBytes = it.sizeBytes,
                freeBytes = state.availableStorageBytes,
                metered = state.meteredNetwork,
            )
        }
    // Settings keeps the richer role-based catalog. Setup gets one answer so
    // people do not have to compare several technical model names.
    val picks = remember(profile, guidance.intent.language, guidance.explicitLanguage) {
        LocalModelCatalog.recommendations(
            if (guidance.explicitLanguage) profile.withExplicitLanguage(guidance.intent.language) else profile,
        )
    }
    val recommended = if (compact) guidance.model ?: picks.first().model else picks.first().model
    val alternates = picks.drop(1)
    val selectedModel = usable.firstOrNull { it.id == selectedModelId }

    var query by remember { mutableStateOf("") }
    var engineFilter by remember { mutableStateOf(ModelEngineFilter.ALL) }
    var sizeFilter by remember { mutableStateOf(ModelSizeFilter.ANY) }
    var languageFilter by remember { mutableStateOf(ModelLanguageFilter.ANY) }
    var inspecting by remember { mutableStateOf<LocalModelDescriptor?>(null) }
    var catalogOpen by remember { mutableStateOf(false) }
    val catalogSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    // Setup's first download, or any on mobile data, is confirmed. A stray tap
    // used to start 661 MB with nothing in between.
    var confirmingDownload by remember { mutableStateOf<LocalModelDescriptor?>(null) }
    val guardedDownloadAndUse: (LocalModelDescriptor) -> Unit = { model ->
        if (compact && (state.downloaded.isEmpty() || state.meteredNetwork)) {
            confirmingDownload = model
        } else {
            onDownloadAndUse(model)
        }
    }

    val filtered = remember(usable, query, engineFilter, sizeFilter, languageFilter) {
        filterModelCatalog(usable, query, engineFilter, sizeFilter, languageFilter)
    }
    val recommendedVisible = if (compact) {
        guidance.model != null && usable.any { it.id == recommended.id }
    } else {
        filtered.any { it.id == recommended.id }
    }
    val installedModels = if (compact) {
        pickerInstalledModels(usable, state.downloaded)
    } else {
        pickerInstalledModels(filtered, state.downloaded)
    }
    // Searching or filtering is a request for the catalog, not for advice: the
    // picks would otherwise sit above results they contradict, and they are
    // taken out of those results below only while they are on screen.
    val browsing = query.isNotBlank() ||
        engineFilter != ModelEngineFilter.ALL ||
        sizeFilter != ModelSizeFilter.ANY ||
        languageFilter != ModelLanguageFilter.ANY
    // Setup shows the alternates too. It used to draw only the lead pick, so
    // a person whose language was covered by the second entry saw a screen
    // that looked like it had one model on it.
    val showAlternates = alternates.isNotEmpty() && !browsing
    val alternateIds = if (showAlternates) alternates.map { it.model.id }.toSet() else emptySet()
    val availableModels = filtered.filter {
        it.id !in state.downloaded &&
            it.id !in alternateIds &&
            !(recommendedVisible && it.id == recommended.id)
    }
    val sections = modelPickerSections(
        recommended = recommended,
        showRecommended = recommendedVisible,
        installed = installedModels,
        available = availableModels,
        compact = compact,
        catalogOpen = catalogOpen,
    )
    val busy = state.downloading != null || state.preparing != null

    if (usable.isEmpty()) {
        Text(
            "No on-device model fits this phone yet.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        return
    }

    if (compact) {
        var catalogPick by remember { mutableStateOf<Pair<String, Int>?>(null) }
        val pickFromCatalog: (LocalModelDescriptor) -> Unit = { model ->
            catalogPick = model.id to ((catalogPick?.second ?: 0) + 1)
        }
        SetupModelChoices(
            state = state,
            usable = usable,
            profile = profile,
            selectedModelId = selectedModelId,
            guidanceLanguage = guidanceLanguage,
            onGuidanceLanguage = onGuidanceLanguage,
            onSelect = onSelect,
            onDownloadAndUse = guardedDownloadAndUse,
            onCancelDownload = onCancelDownload,
            onOpenCatalog = { catalogOpen = true },
            catalogPick = catalogPick,
        )
        CompactCatalogSheet(
            open = catalogOpen,
            onDismiss = { catalogOpen = false },
            sheetState = catalogSheetState,
            query = query,
            onQuery = { query = it },
            engineFilter = engineFilter,
            onEngine = { engineFilter = it },
            sizeFilter = sizeFilter,
            onSize = { sizeFilter = it },
            languageFilter = languageFilter,
            onLanguage = { languageFilter = it },
            available = filtered.filter { it.id !in state.downloaded },
            filteredEmpty = filtered.isEmpty(),
            state = state,
            selectedModelId = selectedModelId,
            onInspect = { inspecting = it },
        )
        confirmingDownload?.let { model ->
            AlertDialog(
                onDismissRequest = { confirmingDownload = null },
                title = { Text(SetupCopy.DOWNLOAD_CONFIRM_TITLE) },
                text = {
                    Text(SetupCopy.downloadConfirmBody(model.displayName, model.sizeLabel, state.meteredNetwork))
                },
                confirmButton = {
                    TextButton(onClick = {
                        confirmingDownload = null
                        onDownloadAndUse(model)
                    }) { Text(SetupCopy.DOWNLOAD_CONFIRM) }
                },
                dismissButton = {
                    TextButton(onClick = { confirmingDownload = null }) { Text("Cancel") }
                },
            )
        }
        inspecting?.let { model ->
            ModelDetailSheet(
                model = model,
                state = state,
                selected = selectedModelId == model.id,
                recommended = false,
                busy = busy,
                onSelect = { onSelect(it); pickFromCatalog(it) },
                onDownloadAndUse = { guardedDownloadAndUse(it); pickFromCatalog(it) },
                onCancelDownload = onCancelDownload,
                onDelete = onDelete,
                onDismiss = { inspecting = null },
            )
        }
        state.message?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }

    if (usingGateway) {
        Text(
            "Speech is going through your gateway. Using a model here switches to this phone.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }

    if (compact && guidance.model == null) {
        Notice {
            Text(
                "No model on this phone matches ${guidance.languageName}.",
                style = MaterialTheme.typography.titleSmall,
            )
            Text(
                "Choose another language or use your self-hosted gateway. Browse shows models that need a different language or setup.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }

    if (
        selectionFromRetiredModel && selectedModel != null &&
        selectedModel.id !in state.downloaded && state.downloading != selectedModel.id
    ) {
        RetiredModelNotice(
            replacement = selectedModel,
            busy = busy,
            onDownload = { onDownloadAndUse(selectedModel) },
        )
    }

    if (!compact && selectedModel != null) {
        Text(
            "In use · ${selectedModel.plain.title} · ${selectedModel.sizeLabel}",
            style = MaterialTheme.typography.bodyMedium,
        )
    }

    if (
        showPickerBusyBanner(
            downloadingId = state.downloading,
            preparingName = state.preparing,
            recommended = sections.recommended,
        )
    ) {
        ModelDownloadCard(state = state, onCancelDownload = onCancelDownload)
    }

    val oversizedWarning = selectedModel != null &&
        LocalModelCatalog.needsHeavierWarning(selectedModel, profile)
    if (oversizedWarning) {
        OversizedModelNotice(
            recommended = recommended,
            installed = recommended.id in state.downloaded,
            busy = busy,
            onSelect = onSelect,
            onDownloadAndUse = onDownloadAndUse,
        )
    }

    sections.recommended?.let { model ->
        if (compact || model.id != selectedModelId) {
            RecommendedModelCard(
                model = model,
                state = state,
                selected = selectedModelId == model.id,
                busy = busy,
                compact = compact,
                showActions = !oversizedWarning,
                onSelect = onSelect,
                onDownloadAndUse = guardedDownloadAndUse,
                onCancelDownload = onCancelDownload,
                onBrowse = if (compact) {
                    { catalogOpen = true }
                } else {
                    null
                },
                guidanceReason = guidance.reason.takeIf { compact },
                guidanceDetail = guidance.downloadDetail.takeIf { compact },
                warning = warning.takeIf { compact },
                alternative = guidanceAlternative.takeIf { compact },
                onUseAlternative = guardedDownloadAndUse,
            )
        }
    }

    confirmingDownload?.let { model ->
        AlertDialog(
            onDismissRequest = { confirmingDownload = null },
            title = { Text(SetupCopy.DOWNLOAD_CONFIRM_TITLE) },
            text = {
                Text(SetupCopy.downloadConfirmBody(model.displayName, model.sizeLabel, state.meteredNetwork))
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmingDownload = null
                    onDownloadAndUse(model)
                }) { Text(SetupCopy.DOWNLOAD_CONFIRM) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingDownload = null }) { Text("Cancel") }
            },
        )
    }

    if (showAlternates) {
        ModelSectionHeading("Also good on this phone")
        ModelPickGrid(
            picks = alternates,
            state = state,
            selectedModelId = selectedModelId,
            onInspect = { inspecting = it },
        )
    }

    run {
        ModelCatalogSearch(
            query = query,
            onQuery = { query = it },
            engineFilter = engineFilter,
            onEngine = { engineFilter = it },
            sizeFilter = sizeFilter,
            onSize = { sizeFilter = it },
            languageFilter = languageFilter,
            onLanguage = { languageFilter = it },
        )
        if (sections.installed.isNotEmpty()) {
            ModelSectionHeading("Installed")
            ModelTileGrid(
                models = sections.installed,
                state = state,
                selectedModelId = selectedModelId,
                onInspect = { inspecting = it },
            )
        }
        AvailableModelCatalog(
            available = sections.catalog,
            filteredEmpty = filtered.isEmpty(),
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

/**
 * The download in progress, with what is moving and how long is left.
 *
 * One composable for the picker, the last setup page, and the home screen, fed
 * by the same [LocalModelState], so a person who finished setup while the model
 * was still coming down sees the same numbers wherever they look — and the
 * three places can never disagree about them.
 */
@Composable
internal fun ModelDownloadCard(state: LocalModelState, onCancelDownload: () -> Unit) {
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
                    modifier = Modifier.weight(1f),
                )
            }
            state.downloading != null -> {
                // The plain name — "Small English" — the same words the model
                // was chosen by, not "Parakeet TDT-CTC 110M English".
                val name = LocalModelCatalog.find(state.downloading)?.plain?.title
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
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = onCancelDownload) { Text("Cancel") }
                }
                LinearProgressIndicator(
                    progress = { state.progress / 100f },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    downloadProgressLine(state),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/**
 * "38% · 254 MB of 670 MB · about 3 minutes left".
 *
 * A bare percentage on a 670 MB download reads as stuck. The size says how much
 * is actually moving, and the estimate is dropped entirely until it has settled
 * rather than shown while it would still swing wildly.
 */
private fun downloadProgressLine(state: LocalModelState): String =
    com.vocahq.vocaphone.local.downloadProgressLine(state)

/**
 * The one sentence a warning is worth. Written so it says what to do, not only
 * what is wrong: "free up space" and "may charge for data" are both actionable,
 * where "insufficient storage" is not.
 */
private fun warningHeadline(warning: DownloadWarning): String = when (warning) {
    is DownloadWarning.NotEnoughStorage ->
        "Needs ${byteLabel(warning.requiredBytes)} free · " +
            "${byteLabel(warning.freeBytes)} available. Free up space first."
    is DownloadWarning.MeteredConnection ->
        "This connection may charge for data · ${byteLabel(warning.sizeBytes)} download."
}

@Composable
private fun RecommendedModelCard(
    model: LocalModelDescriptor,
    state: LocalModelState,
    selected: Boolean,
    busy: Boolean,
    compact: Boolean,
    showActions: Boolean = true,
    onSelect: (LocalModelDescriptor) -> Unit,
    onDownloadAndUse: (LocalModelDescriptor) -> Unit,
    onCancelDownload: () -> Unit,
    onBrowse: (() -> Unit)? = null,
    guidanceReason: String? = null,
    guidanceDetail: String? = null,
    warning: DownloadWarning? = null,
    alternative: LocalModelDescriptor? = null,
    onUseAlternative: (LocalModelDescriptor) -> Unit = {},
) {
    FeaturedCard {
        Text(
            if (compact) "Recommended for you" else "Recommended for this phone",
            style = MaterialTheme.typography.titleSmall,
        )
        // What it is for first, in plain words; the upstream name is the small
        // print for anyone who wants to look it up.
        Text(model.plain.title, style = MaterialTheme.typography.titleMedium)
        Text(
            model.displayName,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        ModelRatings(model.plain)
        Text(
            if (compact) (guidanceDetail ?: model.setupMeta()) else model.catalogMeta(),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            guidanceReason ?: model.recommendationWhy(),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (warning != null) {
            Text(
                warningHeadline(warning),
                style = MaterialTheme.typography.bodySmall,
                // Only the storage case is a hard stop. Painting "you are on
                // mobile data" in the error colour reads as something broken
                // rather than a cost worth knowing.
                color = if (warning is DownloadWarning.NotEnoughStorage) {
                    MaterialTheme.colorScheme.error
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
            )
        }
        // One concrete alternative, named and priced, next to the action it
        // replaces. The warning above is what makes it worth reading; without
        // one it still answers the question everyone has about a 670 MB
        // download, and answers it in a single tap.
        if (alternative != null && alternative.id !in state.downloaded) {
            Text(
                if (warning is DownloadWarning.NotEnoughStorage) {
                    "${alternative.displayName} needs only ${alternative.sizeLabel}."
                } else {
                    "Need something smaller? ${alternative.displayName} · " +
                        "${alternative.sizeLabel}."
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            SecondaryButton(
                text = "Use ${alternative.displayName} instead",
                onClick = { onUseAlternative(alternative) },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (showActions) {
            val browse = onBrowse
            if (
                browse != null &&
                state.downloading != model.id &&
                state.preparing != model.displayName
            ) {
                CompactRecommendedActions(
                    model = model,
                    downloaded = model.id in state.downloaded,
                    selected = selected,
                    busy = busy,
                    onSelect = onSelect,
                    onDownloadAndUse = onDownloadAndUse,
                    onBrowse = browse,
                )
            } else {
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
    }
}

@Composable
private fun CompactRecommendedActions(
    model: LocalModelDescriptor,
    downloaded: Boolean,
    selected: Boolean,
    busy: Boolean,
    onSelect: (LocalModelDescriptor) -> Unit,
    onDownloadAndUse: (LocalModelDescriptor) -> Unit,
    onBrowse: () -> Unit,
) {
    ResponsiveActionRow(
        leading = { item ->
            if (!downloaded) {
                PrimaryButton(
                    text = SetupCopy.DOWNLOAD_AND_CONTINUE,
                    onClick = { onDownloadAndUse(model) },
                    enabled = !busy,
                    modifier = item,
                )
            } else if (selected) {
                Row(
                    modifier = item,
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
            } else {
                SecondaryButton(
                    text = "Use",
                    onClick = { onSelect(model) },
                    enabled = !busy,
                    modifier = item,
                )
            }
        },
        trailing = { item ->
            SecondaryButton(
                text = SetupCopy.BROWSE_MODELS,
                onClick = onBrowse,
                modifier = item,
            )
        },
    )
}

@Composable
private fun ModelCatalogSearch(
    query: String,
    onQuery: (String) -> Unit,
    engineFilter: ModelEngineFilter,
    onEngine: (ModelEngineFilter) -> Unit,
    sizeFilter: ModelSizeFilter,
    onSize: (ModelSizeFilter) -> Unit,
    languageFilter: ModelLanguageFilter,
    onLanguage: (ModelLanguageFilter) -> Unit,
) {
    OutlinedTextField(
        value = query,
        onValueChange = onQuery,
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
        label = { Text("Find a model") },
        placeholder = { Text("Name, language, or engine") },
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FilterChipMenu(
            unselectedLabel = ModelEngineFilter.ALL.displayName,
            options = ModelEngineFilter.entries,
            selected = engineFilter,
            label = { it.displayName },
            isDefault = { it == ModelEngineFilter.ALL },
            onSelect = onEngine,
        )
        FilterChipMenu(
            unselectedLabel = ModelSizeFilter.ANY.displayName,
            options = ModelSizeFilter.entries,
            selected = sizeFilter,
            label = { it.displayName },
            isDefault = { it == ModelSizeFilter.ANY },
            onSelect = onSize,
        )
        FilterChipMenu(
            unselectedLabel = ModelLanguageFilter.ANY.displayName,
            options = ModelLanguageFilter.entries,
            selected = languageFilter,
            label = { it.displayName },
            isDefault = { it == ModelLanguageFilter.ANY },
            onSelect = onLanguage,
        )
    }
}

@Composable
private fun AvailableModelCatalog(
    available: List<LocalModelDescriptor>,
    filteredEmpty: Boolean,
    state: LocalModelState,
    selectedModelId: String,
    onInspect: (LocalModelDescriptor) -> Unit,
    elevated: Boolean = false,
) {
    ModelSectionHeading(
        if (available.isEmpty()) "Catalog" else "Catalog (${available.size})",
    )
    when {
        available.isEmpty() && filteredEmpty -> Text(
            "No models match. Clear the search or a filter.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        available.isEmpty() -> Text(
            "Every matching model is already installed.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        else -> ModelTileGrid(
            models = available,
            state = state,
            selectedModelId = selectedModelId,
            onInspect = onInspect,
            elevated = elevated,
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
    Notice(tone = NoticeTone.Warning) {
        Text(
            "This Whisper model can be slow on this phone. " +
                "${recommended.displayName} is the faster match we would start with.",
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
        modifier = Modifier.padding(top = 4.dp),
    )
}

/** The alternate picks, each labelled with the question it answers. */
@Composable
private fun ModelPickGrid(
    picks: List<ModelPick>,
    state: LocalModelState,
    selectedModelId: String,
    onInspect: (LocalModelDescriptor) -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = AdaptiveLayout.modelGridColumns(
            maxWidth.value,
            LocalDensity.current.fontScale,
        )
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            picks.chunked(columns).forEach { row ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(IntrinsicSize.Min),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    row.forEach { pick ->
                        ModelTile(
                            model = pick.model,
                            selected = pick.model.id == selectedModelId,
                            installed = pick.model.id in state.downloaded,
                            downloading = state.downloading == pick.model.id,
                            progress = state.progress,
                            onClick = { onInspect(pick.model) },
                            modifier = Modifier.weight(1f),
                            roleLabel = pick.role.label,
                        )
                    }
                    if (columns > 1 && row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun ModelTileGrid(
    models: List<LocalModelDescriptor>,
    state: LocalModelState,
    selectedModelId: String,
    onInspect: (LocalModelDescriptor) -> Unit,
    elevated: Boolean = false,
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = AdaptiveLayout.modelGridColumns(
            maxWidth.value,
            LocalDensity.current.fontScale,
        )
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            models.chunked(columns).forEach { row ->
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
                            elevated = elevated,
                        )
                    }
                    if (columns > 1 && row.size == 1) Spacer(Modifier.weight(1f))
                }
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
    elevated: Boolean = false,
    roleLabel: String? = null,
) {
    val colors = MaterialTheme.colorScheme
    val slow = LocalModelCatalog.isSlowOnMobile(model)
    Surface(
        modifier = modifier.fillMaxHeight(),
        onClick = onClick,
        color = when {
            selected -> colors.primaryContainer
            slow -> colors.tertiaryContainer
            elevated -> colors.surfaceContainerHigh
            else -> colors.surfaceContainerLow
        },
        shape = MaterialTheme.shapes.large,
        border = if (selected) BorderStroke(1.dp, colors.primary) else null,
    ) {
        Column(
            modifier = Modifier
                .fillMaxHeight()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (roleLabel != null) {
                Text(
                    roleLabel,
                    style = MaterialTheme.typography.labelSmall,
                    color = if (selected) colors.onPrimaryContainer else colors.primary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                model.plain.title,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                model.displayName,
                style = MaterialTheme.typography.labelSmall,
                color = if (selected) colors.onPrimaryContainer else colors.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${model.sizeLabel} · ${model.engineLabel()}",
                style = MaterialTheme.typography.bodySmall,
                color = if (slow && !selected) colors.onTertiaryContainer else colors.onSurfaceVariant,
            )
            Spacer(Modifier.weight(1f))
            Text(
                when {
                    downloading -> "Downloading $progress%"
                    selected -> "In use"
                    installed -> "Installed"
                    slow -> SetupCopy.SLOW_ON_PHONES
                    else -> model.languages
                },
                style = MaterialTheme.typography.labelSmall,
                color = when {
                    selected || downloading -> colors.primary
                    slow -> colors.tertiary
                    else -> colors.onSurfaceVariant
                },
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
            Text(model.plain.title, style = MaterialTheme.typography.titleLarge)
            Text(
                model.displayName,
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(model.plain.summary, style = MaterialTheme.typography.bodyMedium)
            ModelRatings(model.plain)
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
            if (LocalModelCatalog.isSlowOnMobile(model)) {
                Notice(tone = NoticeTone.Warning) {
                    Text(
                        SetupCopy.SLOW_ON_PHONES_DETAIL,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
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
                modifier = Modifier.weight(1f),
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
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onCancelDownload) { Text("Cancel") }
            }
            LinearProgressIndicator(
                progress = { state.progress / 100f },
                modifier = Modifier.fillMaxWidth(),
            )
            // The recommended card and the detail sheet suppress the busy
            // banner while they are the thing being downloaded, so without
            // this the bar is the only feedback and reads as stuck.
            Text(
                downloadProgressLine(state),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
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

/**
 * The other half of the retired-model migration.
 *
 * Launch can move a stored selection onto its nearest surviving model but
 * cannot download it -- that is hundreds of megabytes the person has not agreed
 * to -- so until they do, dictation stops before recording with "Voice model
 * needed" and the keyboard opens this page. This card is what that page owes
 * them: why the model changed, what it will cost, and the one button that
 * fixes it.
 */
@Composable
private fun RetiredModelNotice(
    replacement: LocalModelDescriptor,
    busy: Boolean,
    onDownload: () -> Unit,
) {
    Notice(tone = NoticeTone.Warning) {
        Text("Your voice model was updated", style = MaterialTheme.typography.titleSmall)
        Text(
            "The model you were using is no longer offered. Its closest replacement is " +
                "“${replacement.plain.title}”: ${replacement.plain.summary} " +
                "Download it to keep dictating on this phone.",
            style = MaterialTheme.typography.bodySmall,
        )
        PrimaryButton(
            text = "Download ${replacement.sizeLabel}",
            onClick = onDownload,
            enabled = !busy,
        )
    }
}

/**
 * Accuracy and speed as four dots each: two answers a person can compare at a
 * glance without knowing what a word error rate is. See [ModelPlainLanguage]
 * for where the numbers come from.
 */
@Composable
internal fun ModelRatings(plain: ModelPlainLanguage) {
    Row(
        modifier = Modifier.clearAndSetSemantics {
            contentDescription = plain.accessibilityRatings
        },
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RatingDots("Accuracy", plain.accuracy)
        RatingDots("Speed", plain.speed)
    }
}

@Composable
private fun RatingDots(label: String, value: Int) {
    val colors = MaterialTheme.colorScheme
    Row(
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = colors.onSurfaceVariant,
            modifier = Modifier.padding(end = 2.dp),
        )
        repeat(ModelPlainLanguage.MAXIMUM_RATING) { index ->
            androidx.compose.foundation.layout.Box(
                Modifier
                    .size(6.dp)
                    .background(
                        if (index < value) colors.primary else colors.outlineVariant,
                        CircleShape,
                    ),
            )
        }
    }
}

/**
 * Setup's model page: one question — which language — and at most three rows
 * named by what they trade, the best one already picked.
 *
 * It replaces a recommended card with ratings, an upstream name and a reason
 * line, a "Use X instead" alternative, a "Choose language" sheet asking two
 * questions, an "Also good on this phone" grid and an "Installed" grid. The
 * rest of the catalog is one tap away, under All models.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SetupModelChoices(
    state: LocalModelState,
    usable: List<LocalModelDescriptor>,
    profile: DeviceProfile,
    selectedModelId: String,
    guidanceLanguage: String,
    onGuidanceLanguage: (String) -> Unit,
    onSelect: (LocalModelDescriptor) -> Unit,
    onDownloadAndUse: (LocalModelDescriptor) -> Unit,
    onCancelDownload: () -> Unit,
    onOpenCatalog: () -> Unit,
    /** The model last used or started from All models, with a counter so a repeat still lands. */
    catalogPick: Pair<String, Int>?,
) {
    var language by rememberSaveable(guidanceLanguage) {
        mutableStateOf(guidanceLanguage.ifBlank { TranscriptionLanguage.AUTOMATIC.wireValue })
    }
    var choosingLanguage by remember { mutableStateOf(false) }
    val choices = remember(profile, language) { ModelChoices.choices(profile, language) }
    val guided = remember(profile, language) { ModelGuidance.recommend(profile, ModelGuidanceIntent(language)) }
    val languageName = guided.languageName
    // The choices, then anything else already here or on its way — but only
    // models that hear the chosen language. A model got from All models has
    // to show up on the page it was chosen for; an English-only one does not
    // belong on a French page with a "Use this model" button under it.
    val rows: List<Pair<LocalModelDescriptor, ModelChoices.Kind?>> =
        remember(choices, usable, state.downloaded, state.downloading, guided.intent.language) {
            val ids = choices.map { it.model.id }.toSet()
            choices.map { it.model to it.kind } +
                usable.filter {
                    (it.id in state.downloaded || it.id == state.downloading) &&
                        it.id !in ids &&
                        it.coversLanguage(guided.intent.language)
                }.map { it to null }
        }
    // Whatever is already in use or on its way wins over the suggestion, so
    // coming back to the page does not offer a second download.
    var picked by rememberSaveable(language) {
        mutableStateOf(
            rows.firstOrNull { it.first.id == selectedModelId && it.first.id in state.downloaded }?.first?.id
                ?: rows.firstOrNull { it.first.id == state.downloading }?.first?.id
                ?: rows.firstOrNull()?.first?.id,
        )
    }
    // A model put in use, or started, from All models is this page's pick too;
    // otherwise the radio would mark one model and offer to use another. Only
    // that explicit action moves the pick — not a download finishing or a
    // model being adopted, which would overwrite a row chosen since.
    //
    // Applied once, when its row exists: a download confirmed in a dialog
    // only becomes a row after the tap that asked for it.
    var appliedCatalogPick by remember { mutableStateOf<Pair<String, Int>?>(null) }
    LaunchedEffect(catalogPick, rows) {
        val pick = catalogPick ?: return@LaunchedEffect
        if (pick != appliedCatalogPick && rows.any { it.first.id == pick.first }) {
            picked = pick.first
            appliedCatalogPick = pick
        }
    }
    val pickedModel = rows.firstOrNull { it.first.id == picked }?.first
    val busy = state.downloading != null || state.preparing != null

    Surface(
        onClick = { choosingLanguage = true },
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_language),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
            )
            Text("I speak", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
            Text(languageName, style = MaterialTheme.typography.titleMedium)
            Icon(
                painter = painterResource(R.drawable.ic_chevron),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }

    if (choices.isEmpty()) {
        Notice {
            Text("No model on this phone understands $languageName yet.", style = MaterialTheme.typography.titleSmall)
            Text("Pick another language, or skip for now.", style = MaterialTheme.typography.bodySmall)
        }
    }

    if (rows.isNotEmpty()) {
        Surface(
            shape = MaterialTheme.shapes.large,
            color = MaterialTheme.colorScheme.surfaceContainerLow,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column {
                rows.forEachIndexed { index, (model, kind) ->
                    if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    SetupModelChoiceRow(
                        model = model,
                        kind = kind,
                        languageName = languageName,
                        best = choices.firstOrNull()?.model,
                        state = state,
                        selected = picked == model.id,
                        onClick = { picked = model.id },
                    )
                }
            }
        }
    }

    if (state.downloading != null) {
        ModelDownloadCard(state = state, onCancelDownload = onCancelDownload)
    }

    pickedModel?.let { model ->
        when {
            model.id !in state.downloaded && state.downloading != model.id -> PrimaryButton(
                text = "Download · ${model.sizeLabel}",
                onClick = { onDownloadAndUse(model) },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            )
            model.id in state.downloaded && model.id != selectedModelId -> PrimaryButton(
                text = "Use this model",
                onClick = { onSelect(model) },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            )
            else -> Unit
        }
    }
    TextButton(onClick = onOpenCatalog) { Text("See all ${usable.size} models") }

    if (choosingLanguage) {
        ModelLanguageSheet(
            selected = language,
            onPick = { code ->
                language = code
                onGuidanceLanguage(code)
                choosingLanguage = false
            },
            onDismiss = { choosingLanguage = false },
        )
    }
}

@Composable
private fun SetupModelChoiceRow(
    model: LocalModelDescriptor,
    kind: ModelChoices.Kind?,
    languageName: String,
    best: LocalModelDescriptor?,
    state: LocalModelState,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val title = when (kind) {
        ModelChoices.Kind.BEST -> "Best for $languageName"
        ModelChoices.Kind.SMALLER -> "Smaller download"
        ModelChoices.Kind.MORE_LANGUAGES -> "More languages"
        null -> model.plain.title
    }
    val tradeOff = when (kind) {
        // The balanced pick: accurate, and quick on this phone. Not always the
        // single most accurate model — More languages can outrate it.
        ModelChoices.Kind.BEST -> "The best fit for $languageName on this phone."
        ModelChoices.Kind.SMALLER ->
            if (best != null && model.plain.accuracy < best.plain.accuracy) {
                "Quicker to download. Makes a few more mistakes."
            } else {
                "Quicker to download, and nearly as accurate."
            }
        ModelChoices.Kind.MORE_LANGUAGES ->
            if (model.languageCodes.isEmpty()) {
                "Understands about 100 languages, if you switch between them."
            } else {
                "Understands ${model.languageCodes.size} languages and tells them apart."
            }
        null -> model.plain.summary
    }
    val status = when {
        state.downloading == model.id -> "Downloading · ${downloadProgressLine(state)}"
        model.id in state.downloaded -> "On this phone · ${model.sizeLabel}"
        kind == null -> model.sizeLabel
        else -> "${model.sizeLabel} · ${model.plain.title}"
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 14.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        RadioButton(selected = selected, onClick = null)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f, fill = false))
                if (kind == ModelChoices.Kind.BEST) {
                    Surface(
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.primaryContainer,
                    ) {
                        Text(
                            "Recommended",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onPrimaryContainer,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                        )
                    }
                }
            }
            Text(tradeOff, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                status,
                style = MaterialTheme.typography.labelMedium,
                color = if (state.downloading == model.id || model.id in state.downloaded) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
            )
        }
    }
}

/**
 * Every language the models know, searchable. A dropdown of sixty entries was
 * a list to scroll with nothing to type into.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelLanguageSheet(
    selected: String,
    onPick: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    val options = remember {
        TranscriptionLanguage.entries
            .filter { it != TranscriptionLanguage.AUTOMATIC }
            .sortedBy { it.displayName }
    }
    val matches = options.filter { query.isBlank() || it.displayName.contains(query.trim(), ignoreCase = true) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Language you speak", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text("Search languages") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            LazyColumn(modifier = Modifier.fillMaxWidth().heightIn(max = 480.dp)) {
                items(matches, key = { it.wireValue }) { option ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onPick(option.wireValue) }
                            .padding(vertical = 14.dp, horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(option.displayName, modifier = Modifier.weight(1f))
                        if (option.wireValue == selected) {
                            Icon(
                                painter = painterResource(R.drawable.ic_step_done),
                                contentDescription = "Selected",
                                tint = MaterialTheme.colorScheme.primary,
                            )
                        }
                    }
                }
            }
        }
    }
}

/** All models, from setup: the full catalog with its search and filters. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CompactCatalogSheet(
    open: Boolean,
    onDismiss: () -> Unit,
    sheetState: androidx.compose.material3.SheetState,
    query: String,
    onQuery: (String) -> Unit,
    engineFilter: ModelEngineFilter,
    onEngine: (ModelEngineFilter) -> Unit,
    sizeFilter: ModelSizeFilter,
    onSize: (ModelSizeFilter) -> Unit,
    languageFilter: ModelLanguageFilter,
    onLanguage: (ModelLanguageFilter) -> Unit,
    available: List<LocalModelDescriptor>,
    filteredEmpty: Boolean,
    state: LocalModelState,
    selectedModelId: String,
    onInspect: (LocalModelDescriptor) -> Unit,
) {
    if (!open) return
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(SetupCopy.BROWSE_SHEET_TITLE, style = MaterialTheme.typography.titleLarge)
            Text(
                SetupCopy.BROWSE_SHEET_SUPPORTING,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            ModelCatalogSearch(
                query = query,
                onQuery = onQuery,
                engineFilter = engineFilter,
                onEngine = onEngine,
                sizeFilter = sizeFilter,
                onSize = onSize,
                languageFilter = languageFilter,
                onLanguage = onLanguage,
            )
            AvailableModelCatalog(
                available = available,
                filteredEmpty = filteredEmpty,
                state = state,
                selectedModelId = selectedModelId,
                onInspect = onInspect,
                elevated = true,
            )
        }
    }
}
