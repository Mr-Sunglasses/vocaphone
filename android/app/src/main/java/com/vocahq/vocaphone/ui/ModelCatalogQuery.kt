package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelEngine

enum class ModelEngineFilter(val displayName: String) {
    ALL("All engines"),
    WHISPER("Whisper"),
    SHERPA("Sherpa"),
}

enum class ModelSizeFilter(val displayName: String, val maxBytes: Long?) {
    ANY("Any size", null),
    UNDER_100MB("Under 100 MB", 100_000_000L),
    UNDER_250MB("Under 250 MB", 250_000_000L),
    UNDER_600MB("Under 600 MB", 600_000_000L),
}

enum class ModelLanguageFilter(val displayName: String) {
    ANY("Any language"),
    ENGLISH("English"),
    MULTILINGUAL("Multilingual"),
}

fun LocalModelDescriptor.engineLabel(): String = when (engine) {
    LocalModelEngine.WHISPER -> "Whisper"
    LocalModelEngine.SHERPA_ONNX -> "Sherpa"
}

fun LocalModelDescriptor.catalogMeta(recommended: Boolean = false): String = buildString {
    append(sizeLabel)
    append(" · ")
    append(engineLabel())
    append(" · ")
    append(languages)
    if (recommended) append(" · recommended")
}

/** Size and languages only. First-run does not need engine or hardware. */
fun LocalModelDescriptor.setupMeta(): String = "$sizeLabel · $languages"

/**
 * What the model picker puts on the page.
 *
 * Compact setup keeps the catalog off the page until More models is opened.
 * Settings always shows the filtered catalog inline.
 */
data class ModelPickerSections(
    val recommended: LocalModelDescriptor?,
    val installed: List<LocalModelDescriptor>,
    val catalog: List<LocalModelDescriptor>,
    val showCatalog: Boolean,
)

/** One progress UI: the recommended card owns its own download or load. */
fun showPickerBusyBanner(
    downloadingId: String?,
    preparingName: String?,
    recommended: LocalModelDescriptor?,
): Boolean {
    if (preparingName != null) {
        return recommended == null || preparingName != recommended.displayName
    }
    if (downloadingId != null) {
        return recommended == null || downloadingId != recommended.id
    }
    return false
}

fun modelPickerSections(
    recommended: LocalModelDescriptor,
    showRecommended: Boolean,
    installed: List<LocalModelDescriptor>,
    available: List<LocalModelDescriptor>,
    compact: Boolean,
    catalogOpen: Boolean,
): ModelPickerSections {
    val showCatalog = !compact || catalogOpen
    return ModelPickerSections(
        recommended = recommended.takeIf { showRecommended },
        installed = installed,
        catalog = if (showCatalog) available else emptyList(),
        showCatalog = showCatalog,
    )
}

fun filterModelCatalog(
    models: List<LocalModelDescriptor>,
    query: String,
    engine: ModelEngineFilter = ModelEngineFilter.ALL,
    size: ModelSizeFilter = ModelSizeFilter.ANY,
    language: ModelLanguageFilter = ModelLanguageFilter.ANY,
): List<LocalModelDescriptor> {
    val needle = query.trim()
    return models.filter { model ->
        matchesEngine(model, engine) &&
            matchesSize(model, size) &&
            matchesLanguage(model, language) &&
            matchesQuery(model, needle)
    }
}

private fun matchesEngine(model: LocalModelDescriptor, engine: ModelEngineFilter): Boolean =
    when (engine) {
        ModelEngineFilter.ALL -> true
        ModelEngineFilter.WHISPER -> model.engine == LocalModelEngine.WHISPER
        ModelEngineFilter.SHERPA -> model.engine == LocalModelEngine.SHERPA_ONNX
    }

private fun matchesSize(model: LocalModelDescriptor, size: ModelSizeFilter): Boolean =
    size.maxBytes == null || model.sizeBytes < size.maxBytes

private fun matchesLanguage(model: LocalModelDescriptor, language: ModelLanguageFilter): Boolean =
    when (language) {
        ModelLanguageFilter.ANY -> true
        ModelLanguageFilter.ENGLISH -> model.englishOnly
        ModelLanguageFilter.MULTILINGUAL -> !model.englishOnly
    }

private fun matchesQuery(model: LocalModelDescriptor, query: String): Boolean {
    if (query.isEmpty()) return true
    return model.displayName.contains(query, ignoreCase = true) ||
        model.id.contains(query, ignoreCase = true) ||
        model.languages.contains(query, ignoreCase = true) ||
        model.engineLabel().contains(query, ignoreCase = true)
}
