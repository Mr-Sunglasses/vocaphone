package com.vocahq.vocaphone.telemetry

import com.vocahq.vocaphone.BuildConfig

/**
 * Where usage reporting goes, whether it is compiled in at all, and what it
 * defaults to.
 *
 * ## What the backend is
 *
 * A self-hosted [Aptabase](https://github.com/aptabase/aptabase) instance
 * (AGPL-3.0) that VocaHQ runs. No third-party analytics service sits in the
 * path, and no analytics SDK is linked into this APK: [AptabaseSink] is about
 * a hundred lines against Aptabase's documented ingest API, which is one POST
 * of a JSON array. Writing it here rather than taking the dependency is what
 * lets `systemProps` stay narrower than the official SDK's (see
 * [TelemetrySystemProps]) and keeps the F-Droid flavour's dependency graph
 * unchanged.
 *
 * ## Why there is no install identifier anywhere in this package
 *
 * Aptabase derives its anonymous user hash server-side from the request's IP
 * address, the User-Agent, and a per-app salt that is discarded every 24 hours.
 * Nothing identifying is stored on the phone, and because the salt is thrown
 * away, the same device on two different days produces two unrelated hashes
 * that nobody — including whoever holds root on the server — can join back
 * together afterwards.
 *
 * That is why the settings screen offers no "reset my ID" button: there is no
 * ID to reset. It is also why [TelemetryEvent.ONE_SHOT] exists. Daily rotation
 * makes per-user funnels impossible, so the funnel is reconstructed from ratios
 * of one-shot counters instead — `first_dictation_ever` over `app_first_open`
 * is the activation rate, with no identity involved at any point.
 *
 * The cost, stated plainly because it is real: no retention curves, and no
 * multi-day funnels. Re-introducing a persistent identifier would buy those
 * back and should be argued on its own merits, not slipped in here.
 */
object TelemetryConfig {

    /**
     * The one line that decides opt-in versus opt-out.
     *
     * `false` means the onboarding step and the settings switch both start off,
     * and nothing is ever queued until the user turns it on. Flipping it to
     * `true` also obliges the onboarding step to become blocking rather than a
     * card that can be scrolled past, and obliges `docs/privacy.md` to say so
     * in its first paragraph.
     *
     * It stays `false` on the merits of the audience rather than the law:
     * because Aptabase stores no identifier on the phone, the ePrivacy consent
     * hook that would normally force opt-in does not apply. The people who
     * install a self-hosted dictation keyboard are simply not the people to
     * surprise with a default-on network call.
     */
    const val DEFAULT_ENABLED = false

    /** Compiled out entirely in the F-Droid flavour; see `build.gradle.kts`. */
    val compiledIn: Boolean get() = BuildConfig.TELEMETRY

    val host: String get() = BuildConfig.APTABASE_HOST

    /**
     * A self-hosted Aptabase app key, which carries the `SH` region prefix that
     * tells a client it must be pointed at a custom host rather than at
     * `eu.`/`us.aptabase.com`.
     *
     * Not in the same class as the gateway bearer token, which is sealed in the
     * Keystore. This one is append-only — it can add events and cannot read the
     * dashboard or reach anything else — and it ships inside the APK, so it is
     * committed rather than injected. See `build.gradle.kts` for the reasoning
     * and for how a fork overrides it.
     */
    val appKey: String get() = BuildConfig.APTABASE_KEY

    /**
     * `A-SH-` plus something. The prefix is Aptabase's own marker for a
     * self-hosted key, and it is the one cheap check that catches both an
     * emptied key and a cloud key pasted in by mistake — the latter would
     * otherwise send this app's events to `eu.aptabase.com`.
     */
    fun isSelfHostedKey(key: String): Boolean =
        key.startsWith(SELF_HOSTED_PREFIX) && key.length > SELF_HOSTED_PREFIX.length

    const val SELF_HOSTED_PREFIX = "A-SH-"

    /**
     * Whether this build may open a socket at all. Decided once, at
     * construction, by which [TelemetrySink] gets bound — [Telemetry] itself
     * never consults it.
     *
     * Debug and source builds never transmit, whatever [DEFAULT_ENABLED] says,
     * so contributors and CI cannot pollute the dataset with runs of a tree
     * that corresponds to no release. They still queue events, which is what
     * makes the "See what's sent" screen useful while developing the feature.
     *
     * A blank host, or a key that is not a well-formed self-hosted one, also
     * disables transmission — so a fork that blanked or mangled it reports
     * nowhere rather than firing requests at a host that will only reject them.
     */
    val canTransmit: Boolean
        get() = compiledIn && !BuildConfig.DEBUG &&
            host.isNotBlank() && isSelfHostedKey(appKey)

    /** Aptabase rejects anything larger; the queue chunks to match. */
    const val MAX_BATCH = 25

    /**
     * Events held before the oldest are dropped.
     *
     * Bounded and in-memory on purpose. Because there is no persistent
     * identity, an event that never reaches the server is simply gone, and
     * that is fine — durable disk-backed retry would be more storage, more
     * code, and more privacy surface than the data is worth.
     */
    const val MAX_QUEUE = 200

    /**
     * How long to wait after an event before sending, coalescing whatever else
     * arrives in that window.
     *
     * This is the primary flush trigger, not a fallback. Most dictations happen
     * inside the IME while the companion app has no activity on screen at all,
     * and `ProcessLifecycleOwner` — which only sees activities — never reports a
     * background transition in that case. Waiting for one meant a keyboard-only
     * dictation queued its event and never sent it, right up until the process
     * died. Flushing shortly after the event itself is the only trigger that
     * fires for every surface: the keyboard, the recording service, and the app.
     *
     * Long enough to batch a dictation's events into one request, short enough
     * that the IME process is still alive to make it.
     */
    const val FLUSH_DEBOUNCE_MILLIS = 5_000L

    /** Identifies this hand-rolled client in `systemProps`, in the SDK's format. */
    const val SDK_VERSION = "vocaphone-telemetry@1"

    const val INGEST_PATH = "/api/v0/events"
}
