package com.vocahq.vocaphone.ui

import android.os.SystemClock
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.local.DeviceProfile
import com.vocahq.vocaphone.local.DownloadWarning
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.local.ModelGuidance
import com.vocahq.vocaphone.local.ModelGuidanceIntent
import com.vocahq.vocaphone.local.ModelGuidancePriority
import com.vocahq.vocaphone.local.ModelGuidanceResult
import com.vocahq.vocaphone.local.ModelPick
import com.vocahq.vocaphone.local.byteLabel
import com.vocahq.vocaphone.local.downloadSizeProgress
import com.vocahq.vocaphone.local.downloadTimeRemaining
import com.vocahq.vocaphone.local.downloadWarning
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
) {
    val usable = remember(state.totalRamGB) {
        LocalModelCatalog.usableOnDevice(state.totalRamGB).sortedBy { it.sizeBytes }
    }
    val profile = remember(state.totalRamGB) {
        DeviceProfile.current(state.totalRamGB)
    }
    var guidancePriority by rememberSaveable { mutableStateOf(ModelGuidancePriority.BALANCED) }
    var guidanceOpen by rememberSaveable { mutableStateOf(false) }
    var guidanceLanguageSelection by rememberSaveable(guidanceLanguage, profile.language) {
        mutableStateOf(guidanceLanguage.ifBlank { TranscriptionLanguage.AUTOMATIC.wireValue })
    }
    val selectedGuidanceLanguage = if (
        guidanceLanguageSelection.isBlank() ||
            guidanceLanguageSelection == TranscriptionLanguage.AUTOMATIC.wireValue
    ) {
        profile.language
    } else {
        guidanceLanguageSelection
    }
    val guidanceProfile = remember(profile, selectedGuidanceLanguage) {
        profile.copy(language = selectedGuidanceLanguage)
    }
    val guidance = remember(guidanceProfile, guidancePriority) {
        ModelGuidance.recommend(
            guidanceProfile,
            ModelGuidanceIntent(
                language = guidanceProfile.language,
                priority = guidancePriority,
            ),
        )
    }
    // The same guidance run at the other end of the trade-off. Shown as one
    // concrete swap rather than a grid: the setup card stays a single answer,
    // but the fact that a 32 MB option exists no longer lives only behind a
    // sheet most people never open.
    val lighter = remember(guidanceProfile) {
        ModelGuidance.recommend(
            guidanceProfile,
            ModelGuidanceIntent(
                language = guidanceProfile.language,
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
    val picks = remember(profile, guidance.intent.language) {
        LocalModelCatalog.recommendations(
            profile.copy(language = guidance.intent.language),
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
    val showAlternates = alternates.isNotEmpty() && !compact && !browsing
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

    if (!compact && selectedModel != null) {
        Text(
            "In use · ${selectedModel.displayName} · ${selectedModel.sizeLabel}",
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
        ModelBusyBanner(state = state, onCancelDownload = onCancelDownload)
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
                onDownloadAndUse = onDownloadAndUse,
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
                onUseAlternative = onDownloadAndUse,
            )
        }
    }

    if (compact) {
        SecondaryButton(
            text = SetupCopy.HELP_ME_CHOOSE,
            onClick = { guidanceOpen = true },
            enabled = !busy,
            modifier = Modifier.fillMaxWidth(),
        )
        // Names the two answers the pick was made on. Without it the button
        // reads as an unrelated second question rather than a way to change
        // something the screen has already decided.
        Text(
            "Chosen for ${guidance.languageName} · ${guidancePriority.title}.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
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

    if (compact) {
        if (sections.installed.isNotEmpty()) {
            ModelSectionHeading("Installed")
            ModelTileGrid(
                models = sections.installed,
                state = state,
                selectedModelId = selectedModelId,
                onInspect = { inspecting = it },
            )
        }
        if (sections.recommended == null) {
            SecondaryButton(
                text = SetupCopy.BROWSE_MODELS,
                onClick = { catalogOpen = true },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    } else {
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

    if (compact && catalogOpen) {
        ModalBottomSheet(
            onDismissRequest = { catalogOpen = false },
            sheetState = catalogSheetState,
        ) {
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
                    onQuery = { query = it },
                    engineFilter = engineFilter,
                    onEngine = { engineFilter = it },
                    sizeFilter = sizeFilter,
                    onSize = { sizeFilter = it },
                    languageFilter = languageFilter,
                    onLanguage = { languageFilter = it },
                )
                AvailableModelCatalog(
                    available = sections.catalog,
                    filteredEmpty = filtered.isEmpty(),
                    state = state,
                    selectedModelId = selectedModelId,
                    onInspect = { inspecting = it },
                    elevated = true,
                )
            }
        }
    }

    if (compact && guidanceOpen) {
        ModelGuidanceSheet(
            selected = guidancePriority,
            selectedLanguage = guidanceLanguageSelection,
            deviceLanguageName = deviceLanguageDisplayName(profile.language),
            previewFor = { language, priority ->
                val resolved = if (
                    language.isBlank() || language == TranscriptionLanguage.AUTOMATIC.wireValue
                ) {
                    profile.language
                } else {
                    language
                }
                ModelGuidance.recommend(
                    profile.copy(language = resolved),
                    ModelGuidanceIntent(language = resolved, priority = priority),
                )
            },
            onApply = { language, priority ->
                guidanceLanguageSelection = language
                guidancePriority = priority
                onGuidanceLanguage(language)
                guidanceOpen = false
            },
            onDismiss = { guidanceOpen = false },
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
                    modifier = Modifier.weight(1f),
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
private fun downloadProgressLine(state: LocalModelState): String {
    // Read at each recomposition, which progress updates already drive often
    // enough to keep the estimate current without a timer of its own.
    val elapsed = if (state.startedAtMillis > 0) {
        SystemClock.elapsedRealtime() - state.startedAtMillis
    } else {
        0L
    }
    return listOfNotNull(
        "${state.progress}%",
        downloadSizeProgress(state.downloadedBytes, state.totalBytes),
        downloadTimeRemaining(state.downloadedBytes, state.totalBytes, elapsed),
    ).joinToString(" · ")
}

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
        Text(model.displayName, style = MaterialTheme.typography.titleMedium)
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelGuidanceSheet(
    selected: ModelGuidancePriority,
    selectedLanguage: String,
    deviceLanguageName: String,
    previewFor: (String, ModelGuidancePriority) -> ModelGuidanceResult,
    onApply: (String, ModelGuidancePriority) -> Unit,
    onDismiss: () -> Unit,
) {
    var languageSelection by rememberSaveable(selectedLanguage) {
        mutableStateOf(selectedLanguage.ifBlank { TranscriptionLanguage.AUTOMATIC.wireValue })
    }
    var prioritySelection by rememberSaveable(selected) { mutableStateOf(selected) }
    // Only languages that survive TranscriptionLanguage.fromWire are offered:
    // an unlisted code round-trips to AUTOMATIC, which silently discarded the
    // choice the moment it was applied. "Use phone language" is the honest row
    // for a locale the catalog has no entry for.
    val languageOptions = remember {
        buildList {
            add(TranscriptionLanguage.AUTOMATIC.wireValue)
            addAll(
                TranscriptionLanguage.entries
                    .filter { it != TranscriptionLanguage.AUTOMATIC }
                    .map { it.wireValue },
            )
        }
    }
    val preview = previewFor(languageSelection, prioritySelection)

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                // Two questions, three options and a live preview do not fit a
                // half-height sheet on a small phone, and the confirm button is
                // the last thing in the column.
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Tell us about your dictation", style = MaterialTheme.typography.titleLarge)
            Text(
                "Choose the language you speak most and what matters most for the download. " +
                    "The match below updates as you choose.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text("Primary language", style = MaterialTheme.typography.titleMedium)
            SettingDropdown(
                options = languageOptions,
                selected = languageSelection,
                label = { guidanceLanguageLabel(it, deviceLanguageName) },
                detail = { guidanceLanguageDetail(it, deviceLanguageName) },
                onSelect = { languageSelection = it },
            )
            Text("What matters most?", style = MaterialTheme.typography.titleMedium)
            ModelGuidancePriority.entries.forEach { priority ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (priority == prioritySelection) {
                        PrimaryButton(
                            text = priority.title,
                            onClick = {
                                prioritySelection = priority
                            },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    } else {
                        SecondaryButton(
                            text = priority.title,
                            onClick = {
                                prioritySelection = priority
                            },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    Text(
                        priority.detail,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            // Two abstract questions with no visible consequence is what made
            // this sheet hard to answer. The match recomputes as either answer
            // changes, so the trade-off is read before it is committed.
            Text("You would get", style = MaterialTheme.typography.titleMedium)
            val previewModel = preview.model
            if (previewModel == null) {
                Text(
                    preview.reason,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                Text(previewModel.displayName, style = MaterialTheme.typography.titleSmall)
                Text(
                    preview.downloadDetail ?: previewModel.sizeLabel,
                    style = MaterialTheme.typography.bodyMedium,
                )
                Text(
                    preview.reason,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            PrimaryButton(
                text = "Use this match",
                onClick = { onApply(languageSelection, prioritySelection) },
                enabled = previewModel != null,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

private fun guidanceLanguageLabel(code: String, deviceLanguageName: String): String {
    if (code == TranscriptionLanguage.AUTOMATIC.wireValue) {
        return "Use phone language ($deviceLanguageName)"
    }
    return TranscriptionLanguage.entries
        .firstOrNull { it.wireValue == code }
        ?.displayName
        ?: deviceLanguageDisplayName(code)
}

private fun guidanceLanguageDetail(code: String, deviceLanguageName: String): String =
    if (code == TranscriptionLanguage.AUTOMATIC.wireValue) {
        "Currently detected as $deviceLanguageName."
    } else {
        "Prefer models that cover ${guidanceLanguageLabel(code, deviceLanguageName)}."
    }

private fun deviceLanguageDisplayName(code: String): String =
    TranscriptionLanguage.entries
        .firstOrNull { it.wireValue == code }
        ?.displayName
        ?: Locale.forLanguageTag(code).getDisplayLanguage(Locale.getDefault())
            .ifBlank { code.uppercase(Locale.ROOT) }

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
                model.displayName,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 2,
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
