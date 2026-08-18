import Foundation

/// Where usage reporting goes, whether this build may transmit, and what the
/// switch defaults to.
///
/// ## What the backend is
///
/// A self-hosted [Aptabase](https://github.com/aptabase/aptabase) instance
/// (AGPL-3.0) that VocaHQ runs. No third-party analytics service sits in the
/// path, and no analytics SDK is linked into this app: ``AptabaseSink`` is about
/// a hundred lines against Aptabase's documented ingest API, which is one POST
/// of a JSON array. Writing it here rather than taking the MIT SDK is what lets
/// `systemProps` stay narrower than the SDK's — see ``TelemetrySystemProps`` —
/// and it keeps "no analytics SDK" true in the README and the store listings.
///
/// ## Why there is no install identifier anywhere in this directory
///
/// Aptabase derives its anonymous user hash server-side from the request's IP
/// address, the User-Agent, and a per-app salt that is discarded every 24 hours.
/// Nothing identifying is stored on the phone, and because the salt is thrown
/// away, the same device on two different days produces two unrelated hashes
/// that nobody — including whoever holds root on the server — can join back
/// together afterwards.
///
/// That is why Settings offers no "reset my ID" button: there is no ID to reset.
/// It is also why ``TelemetryEvent/oneShot`` exists. Daily rotation makes
/// per-user funnels impossible, so the funnel is reconstructed from ratios of
/// one-shot counters instead — `first_dictation_ever` over `app_first_open` is
/// the activation rate, with no identity involved at any point.
///
/// The cost, stated plainly because it is real: no retention curves, and no
/// multi-day funnels.
enum TelemetryConfig {

    /// The one constant that decides opt-in versus opt-out.
    ///
    /// `false` means the onboarding step and the settings switch both start off,
    /// and nothing is ever queued until the user turns it on. Flipping it to
    /// `true` also obliges the onboarding step to become blocking rather than a
    /// section that can be scrolled past, and obliges `docs/privacy.md` to say
    /// so in its first paragraph.
    ///
    /// It stays `false` on the merits of the audience rather than the law:
    /// because Aptabase stores no identifier on the phone, the ePrivacy consent
    /// hook that would normally force opt-in does not apply. The people who
    /// install a self-hosted dictation keyboard are simply not the people to
    /// surprise with a default-on network call.
    static let defaultEnabled = false

    static let host = "https://telemetry.vocahq.com"

    /// A self-hosted Aptabase app key, which carries the `SH` region prefix that
    /// tells a client it must be pointed at a custom host rather than at
    /// `eu.`/`us.aptabase.com`.
    ///
    /// Committed on purpose, and not in the same class as the gateway bearer
    /// token that lives in the Keychain. This is an append-only ingest
    /// credential: it can add events and cannot read the dashboard, change the
    /// app, or reach anything else. It also ships inside the binary, so it can
    /// be extracted from any App Store download — keeping it out of the
    /// repository would hide it from contributors and from nobody else.
    ///
    /// The real exposure is someone posting junk events to skew the beta
    /// numbers, which is handled by rate limiting at the reverse proxy and, if
    /// it ever happens, by rotating this key.
    static let appKey = "A-SH-3275173609"

    /// Whether this build may open a socket at all. Consulted once, when the
    /// sink is chosen; ``Telemetry`` itself never checks it.
    ///
    /// DEBUG builds never transmit, whatever ``defaultEnabled`` says, so
    /// development and CI cannot pollute the dataset with runs of a tree that
    /// corresponds to no release. They still queue events, which is what makes
    /// the "See what's sent" screen useful while working on the feature.
    ///
    /// A key that is not a well-formed self-hosted one also disables
    /// transmission, so a fork that blanked or mangled it reports nowhere
    /// rather than firing requests at a host that will only reject them.
    static var canTransmit: Bool {
        #if DEBUG
            false
        #else
            isSelfHostedKey(appKey) && !host.isEmpty
        #endif
    }

    /// `A-SH-` plus something. The prefix is Aptabase's own marker for a
    /// self-hosted key, and it is the one cheap check that catches both an
    /// emptied key and a cloud key pasted in by mistake — the latter would
    /// otherwise send this app's events to `eu.aptabase.com`.
    static func isSelfHostedKey(_ key: String) -> Bool {
        key.hasPrefix("A-SH-") && key.count > "A-SH-".count
    }

    /// Aptabase rejects anything larger; the queue chunks to match.
    static let maxBatch = 25

    /// Events held before the oldest are dropped.
    ///
    /// Bounded and in memory on purpose. Because there is no persistent
    /// identity, an event that never reaches the server is simply gone, and
    /// that is fine — durable retry would be more storage, more code, and more
    /// privacy surface than the data is worth.
    static let maxQueue = 200

    /// How long to wait after an event before sending, coalescing whatever else
    /// arrives in that window.
    ///
    /// This is the primary flush trigger, not a fallback. Waiting only for a
    /// `scenePhase` change means a dictation that happens while the app is
    /// already in the background — Quick Dictation keeps it alive for up to ten
    /// minutes precisely so it can — queues its event and never sends it,
    /// because no transition ever occurs. Flushing shortly after the event
    /// itself is the only trigger that fires regardless of where the app is.
    ///
    /// The Android client had exactly this bug against `ProcessLifecycleOwner`
    /// and it made the whole feature look broken on a real phone.
    static let flushDebounce: Duration = .seconds(5)

    /// Identifies this hand-rolled client in `systemProps`, in the SDK's format.
    static let sdkVersion = "vocaphone-telemetry@1"

    static let ingestPath = "/api/v0/events"

    static var ingestURL: URL? { URL(string: host + ingestPath) }
}
