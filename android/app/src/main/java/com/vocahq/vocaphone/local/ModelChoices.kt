package com.vocahq.vocaphone.local

/**
 * The rows setup offers, named by what they trade rather than by what they are.
 *
 * People pick a download by what it costs them and what it gets right, not by a
 * family name. So setup asks one question — which language — and answers with
 * at most three rows: the model [ModelGuidance] would pick, a much smaller one,
 * and one that hears more languages. Everything else is behind All models.
 *
 * Mirrors `LocalModelCatalog.modelChoices` on iOS; the catalogs differ, the
 * three questions do not.
 */
object ModelChoices {
    enum class Kind { BEST, SMALLER, MORE_LANGUAGES }

    data class Choice(val kind: Kind, val model: LocalModelDescriptor)

    /**
     * A smaller choice has to be a real saving: under this share of the best
     * model's download. Two 600 MB rows offered as "smaller" and "best" are one
     * choice shown twice.
     */
    const val SMALLER_SHARE = 0.6

    /** Best first, each model once. Empty when nothing this phone runs covers [language]. */
    fun choices(profile: DeviceProfile, language: String): List<Choice> {
        fun guided(priority: ModelGuidancePriority) =
            ModelGuidance.recommend(profile, ModelGuidanceIntent(language, priority))

        val balanced = guided(ModelGuidancePriority.BALANCED)
        val best = balanced.model ?: return emptyList()
        // The guidance resolves Automatic to the phone's language; every row
        // has to hear that one.
        val lead = balanced.intent.language
        val candidates = LocalModelCatalog.all.filter {
            LocalModelCatalog.isUsableOnDevice(it, profile.totalRamGB, profile.sherpaAvailable) &&
                profile.fits(it) &&
                it.coversLanguage(lead) &&
                !LocalModelCatalog.isSlowOnMobile(it)
        }
        val choices = mutableListOf(Choice(Kind.BEST, best))

        // Rated best first, then the smaller of two equals, so size never
        // outranks accuracy among the savings.
        val ceiling = best.sizeBytes * SMALLER_SHARE
        candidates
            .filter { it.id != best.id && it.sizeBytes < ceiling }
            .sortedWith(
                compareByDescending<LocalModelDescriptor> { it.plain.accuracy }
                    .thenBy { it.sizeBytes }
                    .thenBy { it.id },
            )
            .firstOrNull()
            ?.let { choices += Choice(Kind.SMALLER, it) }

        // Only when it genuinely hears more than the best one does.
        val wider = guided(ModelGuidancePriority.MULTILINGUAL).model
            ?.takeIf { breadth(it) > breadth(best) && choices.none { c -> c.model.id == it.id } }
            ?: candidates
                .filter { breadth(it) > breadth(best) && choices.none { c -> c.model.id == it.id } }
                .maxWithOrNull(compareBy<LocalModelDescriptor> { it.plain.accuracy }.thenBy { breadth(it) })
        wider?.let { choices += Choice(Kind.MORE_LANGUAGES, it) }
        return choices
    }

    /** An empty language list means no restriction: the multilingual Whisper builds. */
    private fun breadth(model: LocalModelDescriptor): Int = when {
        model.englishOnly -> 1
        model.languageCodes.isEmpty() -> Int.MAX_VALUE
        else -> model.languageCodes.size
    }
}
