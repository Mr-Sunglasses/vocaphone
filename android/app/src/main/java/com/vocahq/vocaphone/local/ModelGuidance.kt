package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.TranscriptionLanguage
import java.util.Locale

/** The small set of practical choices that can change a first-run model. */
enum class ModelGuidancePriority(
    val title: String,
    val detail: String,
) {
    BALANCED(
        title = "Balanced",
        detail = "The best all-round match for this phone and your language.",
    ),
    LIGHTER(
        title = "Smallest download",
        detail = "Least data and storage. Best on a metered connection.",
    ),
    MULTILINGUAL(
        title = "Works across languages",
        detail = "One model for several languages, instead of a specialist in one.",
    ),
}

data class ModelGuidanceIntent(
    val language: String,
    val priority: ModelGuidancePriority = ModelGuidancePriority.BALANCED,
)

enum class ModelGuidanceConfidence {
    GOOD_DEFAULT,
    NO_MATCH,
}

data class ModelGuidanceResult(
    val model: LocalModelDescriptor?,
    val intent: ModelGuidanceIntent,
    val confidence: ModelGuidanceConfidence,
    val reason: String,
) {
    val languageName: String
        get() = guidanceLanguageName(intent.language)

    val isAvailable: Boolean get() = model != null

    val downloadDetail: String?
        get() = model?.let { "Works with $languageName · ${it.sizeLabel} download" }
}

/**
 * A pure, platform-local decision layer for onboarding.
 *
 * The catalog remains the source of truth for runtime and language support. The
 * guidance layer only changes ordering; it cannot return a model that fails the
 * existing device/runtime checks.
 */
object ModelGuidance {
    fun recommend(
        profile: DeviceProfile,
        intent: ModelGuidanceIntent,
    ): ModelGuidanceResult {
        val language = intent.language.lowercase(Locale.ROOT).let {
            if (it.isBlank() || it == TranscriptionLanguage.AUTOMATIC.wireValue) {
                profile.language.lowercase(Locale.ROOT)
            } else {
                it
            }
        }
        val candidates = LocalModelCatalog.all
            .filter {
                LocalModelCatalog.isUsableOnDevice(
                    it,
                    profile.totalRamGB,
                    profile.sherpaAvailable,
                ) && profile.fits(it) && it.coversLanguage(language)
            }

        if (candidates.isEmpty()) {
            return ModelGuidanceResult(
                model = null,
                intent = intent.copy(language = language),
                confidence = ModelGuidanceConfidence.NO_MATCH,
                reason = "No on-device model in this build supports ${guidanceLanguageName(language)} on this phone.",
            )
        }

        val normalized = intent.copy(language = language)
        val rankingProfile = profile.copy(language = language)
        val balanced = LocalModelCatalog.recommended(rankingProfile).takeIf { it in candidates }
            ?: candidates.sortedWith(
                compareByDescending<LocalModelDescriptor> { scoreModel(it, rankingProfile) }
                    .thenBy { it.sizeBytes }
                    .thenBy { it.minimumRamGB }
                    .thenBy { it.id },
            ).first()
        val selected = when (intent.priority) {
            ModelGuidancePriority.BALANCED -> balanced
            ModelGuidancePriority.LIGHTER ->
                candidates.minWith(compareBy<LocalModelDescriptor> { it.sizeBytes }
                    .thenBy { it.minimumRamGB }
                    .thenBy { it.id })
            ModelGuidancePriority.MULTILINGUAL ->
                LocalModelCatalog.bestMultilingual(rankingProfile)
                    ?.takeIf { it in candidates }
                    ?: candidates.maxWith(
                        compareBy<LocalModelDescriptor> { languageBreadth(it) }
                            .thenBy { it.sizeBytes }
                            .thenByDescending { it.id },
                    )
        }

        val languageName = guidanceLanguageName(language)
        val reason = when (intent.priority) {
            ModelGuidancePriority.BALANCED ->
                "A balanced match that fits this phone and covers $languageName."
            ModelGuidancePriority.LIGHTER ->
                "The smallest compatible download that covers $languageName."
            ModelGuidancePriority.MULTILINGUAL ->
                if (selected.id == balanced.id) {
                    "The balanced match already covers several languages on this phone."
                } else {
                    "Covers ${selected.languages}, so you can switch language without " +
                        "switching model. ${qualityDownloadComparison(selected, balanced)}"
                }
        }
        return ModelGuidanceResult(
            model = selected,
            intent = normalized,
            confidence = ModelGuidanceConfidence.GOOD_DEFAULT,
            reason = reason,
        )
    }
}

/** Keep the trade-off copy true even when capability and download size disagree. */
private fun qualityDownloadComparison(
    selected: LocalModelDescriptor,
    balanced: LocalModelDescriptor,
): String = when {
    selected.sizeBytes > balanced.sizeBytes -> "Bigger download than the balanced match."
    selected.sizeBytes < balanced.sizeBytes -> "Smaller download than the balanced match."
    else -> "About the same download size as the balanced match."
}

/**
 * How many languages a model transcribes, for ranking breadth.
 *
 * An empty [LocalModelDescriptor.languageCodes] means no restriction rather
 * than no coverage — that is how the multilingual Whisper builds are declared —
 * so it sorts above every model that names its languages.
 */
private fun languageBreadth(model: LocalModelDescriptor): Int = when {
    model.englishOnly -> 1
    model.languageCodes.isEmpty() -> Int.MAX_VALUE
    else -> model.languageCodes.size
}

private fun guidanceLanguageName(code: String): String {
    val known = TranscriptionLanguage.entries.firstOrNull { it.wireValue == code }
    if (known != null) return known.displayName
    return Locale.forLanguageTag(code).getDisplayLanguage(Locale.getDefault())
        .ifBlank { code.uppercase(Locale.ROOT) }
}
