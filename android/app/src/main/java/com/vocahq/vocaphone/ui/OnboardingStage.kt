package com.vocahq.vocaphone.ui

/**
 * Where a person is in first-run setup.
 *
 * Deliberately separate from [SetupStep]. A step is a requirement, read live
 * from the system every time the app resumes; a stage is a page. Some pages
 * carry a requirement, and some — a welcome, a choice, a confirmation — carry
 * none. Before this split the page *was* the first unmet requirement, which
 * is why there could be no welcome screen, no skip, and no "keyboard ready"
 * moment: each needs a page that is not a requirement.
 *
 * Page position never grants a requirement. That rule is unchanged: [READY]
 * still reads [SetupStatus.isReadyToDictate], and a skipped [MODEL] leaves
 * its requirement unmet, so READY offers "Review remaining setup" exactly as
 * before.
 *
 * Order follows iOS: the big decision first, the download started early so it
 * overlaps the slow system-settings steps, and the keyboard — the step people
 * most often stall on — last, where a stall costs the least.
 */
internal enum class OnboardingStage(
    val title: String,
    val detail: String,
    val step: SetupStep?,
    /** Skip is one page forward and leaves the requirement unmet. */
    val allowsSkip: Boolean = false,
) {
    WELCOME(
        "Dictate into any app",
        "A keyboard that types what you say.",
        step = null,
    ),
    SOURCE(
        "Choose where speech becomes text",
        "On this phone, or a gateway you run.",
        step = null,
    ),
    MODEL(
        "Choose a model",
        "Matched to the languages and keyboards on this phone.",
        step = SetupStep.GATEWAY,
        allowsSkip = true,
    ),
    MICROPHONE(
        "Let your voice do the typing",
        "Allow microphone access so VocaPhone can hear your dictation.",
        step = SetupStep.MICROPHONE,
    ),
    NOTIFICATIONS(
        "Know when you're recording",
        "Allow notifications to keep recording controls within reach.",
        step = SetupStep.NOTIFICATIONS,
    ),
    KEYBOARD(
        "Make room for your voice",
        "Enable VocaPhone and choose it as your keyboard.",
        step = SetupStep.KEYBOARD,
    ),
    /** A confirmation, shown for a moment when the keyboard lands. Never a landing page. */
    KEYBOARD_READY(
        "Keyboard ready",
        "",
        step = null,
    ),
    READY(
        "You're ready to dictate",
        "Your keyboard, permissions, and speech-to-text source are ready.",
        step = null,
    ),
    ;

    /** True when nothing on this page is still wanted. Teaching and choice pages always pass. */
    fun isSatisfied(status: SetupStatus): Boolean = when (this) {
        READY -> status.isReadyToDictate
        else -> step?.let(status::isSatisfied) ?: true
    }

    fun previous(): OnboardingStage {
        // The confirmation is skipped over in both directions: it is a state,
        // not a room, and Back from the page after it should not replay it.
        var target = entries[(ordinal - 1).coerceAtLeast(0)]
        if (target == KEYBOARD_READY) target = KEYBOARD
        return target
    }

    fun next(): OnboardingStage = entries[(ordinal + 1).coerceAtMost(entries.lastIndex)]

    fun advance(status: SetupStatus, localTranscriptionEnabled: Boolean): OnboardingStage = when {
        this == SOURCE -> if (localTranscriptionEnabled) MODEL else resume(MICROPHONE, status)
        else -> resume(next(), status)
    }

    /** Thin top bar. Welcome is a sliver, each page fills it, the confirmation shares KEYBOARD's stop. */
    val progress: Float
        get() = when (this) {
            WELCOME -> 1f / 7f
            SOURCE -> 2f / 7f
            MODEL -> 3f / 7f
            MICROPHONE -> 4f / 7f
            NOTIFICATIONS -> 5f / 7f
            KEYBOARD, KEYBOARD_READY -> 6f / 7f
            READY -> 1f
        }

    companion object {
        /**
         * Where to open on launch.
         *
         * A fresh install starts at the welcome. Otherwise, walk forward from
         * the saved page and stop at the first one still worth showing: a
         * teaching or choice page as saved, or the first requirement not yet
         * met. A requirement granted from Settings while the app was away is
         * walked past — nobody should be asked for the microphone they already
         * allowed. The confirmation is never a landing page.
         */
        fun resume(persisted: OnboardingStage?, status: SetupStatus): OnboardingStage {
            val start = persisted ?: return WELCOME
            for (stage in entries.drop(start.ordinal)) {
                when {
                    stage == READY -> return READY
                    stage == KEYBOARD_READY -> continue
                    stage.step == null -> return stage
                    !status.isSatisfied(stage.step) -> return stage
                }
            }
            return READY
        }

        /**
         * The first requirement still unmet, in page order — for "Review
         * remaining setup" from the end, and for any recovery from a revoked
         * requirement. This is the rule the page used to be derived from.
         */
        fun firstUnmet(status: SetupStatus): OnboardingStage =
            entries.firstOrNull { it.step != null && !status.isSatisfied(it.step) } ?: READY

        /**
         * Decode a saved page. Unknown values — a page a newer build retired —
         * start over rather than crash; that is one screen of repetition
         * against a stuck launch.
         */
        fun persisted(raw: String?): OnboardingStage? =
            raw?.takeIf { it.isNotBlank() }?.let { value -> entries.firstOrNull { it.name == value } }
    }
}
