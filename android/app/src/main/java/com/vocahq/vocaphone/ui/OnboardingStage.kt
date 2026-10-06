package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.BuildConfig

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
 * overlaps the slow system-settings steps, and the input setup — the step
 * people most often stall on — last, where a stall costs the least. The X build
 * builds swap the keyboard pages for a single floating-mic page that carries
 * the disclosure, overlay, and accessibility requirements; [active] is the
 * page list the navigation helpers walk.
 */
internal enum class OnboardingStage(
    val title: String,
    val detail: String,
    val steps: List<SetupStep>,
    /** Skip is one page forward and leaves the requirement unmet. */
    val allowsSkip: Boolean = false,
    /** Whether the page belongs to the keyboard build, the X build, or both. */
    private val path: Path = Path.BOTH,
) {
    WELCOME(
        "Dictate into any app",
        if (BuildConfig.FLOATING_INPUT) {
            "A floating mic that types what you say."
        } else {
            "A keyboard that types what you say."
        },
        steps = emptyList(),
    ),
    /**
     * Also where a gateway is chosen. There is no separate source page: the
     * welcome already says speech stays on this phone unless you run a
     * gateway, and asking again was a page nearly everyone answered the same
     * way.
     */
    MODEL(
        "Choose a model",
        "Matched to the languages and keyboards on this phone.",
        steps = listOf(SetupStep.GATEWAY),
        allowsSkip = true,
    ),
    MICROPHONE(
        "Let your voice do the typing",
        "Allow microphone access so VocaPhone can hear your dictation.",
        steps = listOf(SetupStep.MICROPHONE),
    ),
    NOTIFICATIONS(
        "Know when you're recording",
        "Allow notifications to keep recording controls within reach.",
        steps = listOf(SetupStep.NOTIFICATIONS),
    ),
    KEYBOARD(
        "Make room for your voice",
        "Enable VocaPhone and choose it as your keyboard.",
        steps = listOf(SetupStep.KEYBOARD),
        path = Path.IME,
    ),
    /** A confirmation, shown for a moment when the keyboard lands. Never a landing page. */
    KEYBOARD_READY(
        "Keyboard ready",
        "",
        steps = emptyList(),
        path = Path.IME,
    ),
    /**
     * The X build's one input page: the accessibility disclosure, the overlay
     * permission, and the accessibility service all live together because
     * they are one permission trip out to system settings.
     */
    FLOATING_MIC(
        "Dictate over your favorite keyboard",
        "Allow VocaPhone to float a mic over other apps and insert your words.",
        steps = listOf(SetupStep.DISCLOSURE, SetupStep.OVERLAY, SetupStep.ACCESSIBILITY),
        path = Path.FLOATING,
    ),
    READY(
        "You're ready to dictate",
        if (BuildConfig.FLOATING_INPUT) {
            "Your mic, permissions, and speech-to-text source are ready."
        } else {
            "Your keyboard, permissions, and speech-to-text source are ready."
        },
        steps = emptyList(),
    ),
    ;

    private enum class Path { BOTH, IME, FLOATING }

    private val inActivePath: Boolean
        get() = when (path) {
            Path.BOTH -> true
            Path.IME -> !BuildConfig.FLOATING_INPUT
            Path.FLOATING -> BuildConfig.FLOATING_INPUT
        }

    /** True when nothing on this page is still wanted. Teaching and choice pages always pass. */
    fun isSatisfied(status: SetupStatus): Boolean = when (this) {
        READY -> status.isReadyToDictate
        else -> steps.all(status::isSatisfied)
    }

    fun previous(): OnboardingStage {
        val stages = active()
        var target = stages[(stages.indexOf(this) - 1).coerceAtLeast(0)]
        // The confirmation is skipped over in both directions: it is a state,
        // not a room, and Back from the page after it should not replay it.
        if (target == KEYBOARD_READY) target = KEYBOARD
        return target
    }

    fun next(): OnboardingStage {
        val stages = active()
        return stages[(stages.indexOf(this) + 1).coerceAtMost(stages.lastIndex)]
    }

    fun advance(status: SetupStatus): OnboardingStage = resume(next(), status)

    /** Thin top bar. Welcome is a sliver, each page fills it, the confirmation shares its parent's stop. */
    val progress: Float
        get() = when (this) {
            WELCOME -> 1f / 6f
            MODEL -> 2f / 6f
            MICROPHONE -> 3f / 6f
            NOTIFICATIONS -> 4f / 6f
            KEYBOARD, KEYBOARD_READY, FLOATING_MIC -> 5f / 6f
            READY -> 1f
        }

    companion object {
        /** The page sequence for this build — the keyboard pages or the floating-mic one. */
        fun active(): List<OnboardingStage> = entries.filter { it.inActivePath }

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
            val stages = active()
            val start = persisted?.takeIf { it in stages } ?: return WELCOME
            for (stage in stages.dropWhile { it != start }) {
                when {
                    stage == READY -> return READY
                    stage == KEYBOARD_READY -> continue
                    stage.steps.isEmpty() -> return stage
                    !stage.isSatisfied(status) -> return stage
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
            active().firstOrNull { it.steps.isNotEmpty() && !it.isSatisfied(status) } ?: READY

        /**
         * Decode a saved page. The retired source page resumes on MODEL, where
         * that choice is now made. Other unknown values — a page a newer build
         * retired, or an IME page in a X build — start over rather than
         * crash; that is one screen of repetition against a stuck launch.
         */
        fun persisted(raw: String?): OnboardingStage? =
            raw?.takeIf { it.isNotBlank() }?.let { value ->
                if (value == "SOURCE") MODEL else entries.firstOrNull { it.name == value }
            }
    }
}
