import Foundation

/// The only three things telemetry is allowed to know about the user's settings.
///
/// ``Telemetry`` could just as easily read `KeyboardPreferences` directly, and
/// this protocol exists to make sure it cannot. Through that type it would be
/// one property away from the gateway endpoint, the custom vocabulary, and the
/// learned words — none of which it has any business reading, and all of which
/// someone could plausibly add to an event in a hurry. A three-method contract
/// makes the boundary reviewable at a glance instead of resting on nobody ever
/// taking the shortcut.
protocol TelemetryPreferences: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)

    /// True only the first time `key` is claimed on this install.
    func claimMilestone(_ key: String) -> Bool
}

/// Usage-reporting preferences, in the app group so the setting survives an
/// app update and can be read by the keyboard if v2 ever needs it.
///
/// Only the switch and the milestone flags live here. There is no install
/// identifier, because Aptabase does not use one — see ``TelemetryConfig``.
final class UserDefaultsTelemetryPreferences: TelemetryPreferences {
    static let enabledKey = "telemetryEnabled"
    static let askedKey = "telemetryAsked"
    static let milestonesKey = "telemetryMilestones"

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)) {
        self.defaults = defaults ?? .standard
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? TelemetryConfig.defaultEnabled
    }

    /// Whether the onboarding step has been shown. Separate from ``isEnabled``
    /// because "declined" and "never asked" have to be told apart: without it,
    /// someone who said no would be asked again on every trip through guided
    /// setup.
    var hasBeenAsked: Bool {
        get { defaults.bool(forKey: Self.askedKey) }
        set { defaults.set(newValue, forKey: Self.askedKey) }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func claimMilestone(_ key: String) -> Bool {
        var seen = Set(defaults.stringArray(forKey: Self.milestonesKey) ?? [])
        guard seen.insert(key).inserted else { return false }
        defaults.set(Array(seen).sorted(), forKey: Self.milestonesKey)
        return true
    }
}

/// Everything the rest of the app is allowed to report.
///
/// ## Why every method takes enums
///
/// There is no `track(name:properties:)` here, and there must never be one. Each
/// event gets its own method whose parameters are enums from
/// `TelemetryEvent.swift`, which means a call site physically cannot pass a
/// transcript, a gateway URL, a file path, or a token — not because reviewers
/// will catch it, but because no parameter accepts a string.
///
/// ## What happens when reporting is off
///
/// Nothing is queued. Not "queued and discarded at flush" — the check happens
/// before a ``TelemetryRecord`` is ever constructed, so the interesting failure
/// mode (a queue quietly filling while the switch is off, then flooding the
/// moment someone turns it on) cannot occur.
///
/// ## What happens in a build that must not transmit
///
/// Nothing here checks. Whether this build can reach the network is decided
/// once, at construction, by which ``TelemetrySink`` is bound.
@MainActor
final class Telemetry {

    static let shared = Telemetry()

    private let preferences: TelemetryPreferences
    private let sink: TelemetrySink
    private let systemProps: @Sendable () -> TelemetrySystemProps
    private let clock: () -> Date
    private var queue: TelemetryQueue
    private var session: TelemetrySession
    private let autoFlushDelay: Duration?
    private var flushTask: Task<Void, Never>?
    /// Content-free delivery counters; see ``TelemetryStats`` for why.
    private var stats = TelemetryStats()

    init(
        preferences: TelemetryPreferences = UserDefaultsTelemetryPreferences(),
        sink: TelemetrySink = TelemetryConfig.canTransmit ? AptabaseSink() : NoOpTelemetrySink(),
        queue: TelemetryQueue = TelemetryQueue(),
        session: TelemetrySession = TelemetrySession(),
        systemProps: @escaping @Sendable () -> TelemetrySystemProps = {
            TelemetrySystemProps.current()
        },
        clock: @escaping () -> Date = Date.init,
        /// How long to wait after an event before sending. `nil` disables the
        /// automatic flush entirely, which is what most tests want so that a
        /// batch count means what the test says it means.
        autoFlushDelay: Duration? = TelemetryConfig.flushDebounce
    ) {
        self.autoFlushDelay = autoFlushDelay
        self.preferences = preferences
        self.sink = sink
        self.queue = queue
        self.session = session
        self.systemProps = systemProps
        self.clock = clock
    }

    // MARK: - Events

    /// Once per install, ever. The denominator for every ratio in the funnel.
    func appFirstOpen() { recordOnce(.appFirstOpen) }

    /// Once per step, ever, so a user who redoes setup does not double-count.
    func setupStepCompleted(_ step: TelemetrySetupStep) {
        recordOnce(.setupStepCompleted, ["step": step.rawValue], key: step.rawValue)
    }

    func setupFinished() { recordOnce(.setupFinished) }

    /// Repeats on purpose: switching back to the gateway after trying on-device
    /// is a signal.
    func sourceSelected(_ source: TelemetrySource) {
        record(.sourceSelected, ["source": source.rawValue])
    }

    /// Takes the descriptor rather than its identifier: the value can then only
    /// originate in the shipped catalog, and ``TelemetryModelID/pinned(_:)``
    /// re-checks it against that catalog before it goes anywhere. Every property
    /// whose value begins life as a string goes through that one function.
    func modelDownloadFinished(model: LocalModelDescriptor, outcome: TelemetryDownloadOutcome) {
        record(
            .modelDownloadFinished,
            [
                "model_id": TelemetryModelID.pinned(model),
                "outcome": outcome.rawValue,
            ]
        )
    }

    /// Once ever. Paired with ``appFirstOpen()``, this is the activation rate —
    /// the share of installs that reach a working transcript at all — obtained
    /// without any per-user identity.
    func firstDictationEver() { recordOnce(.firstDictationEver) }

    /// `model` and `quality` describe what the session was *claimed* with, not
    /// what is selected now, and both are mapped rather than passed through:
    /// ``TelemetryModelID/of(_:source:)`` and ``TelemetryQuality/of(_:source:)``
    /// decide what a gateway session reports, so a call site cannot attribute
    /// one to a local model it never touched.
    func dictationSucceeded(
        source: TelemetrySource,
        duration: TelemetryDurationBucket,
        model: LocalModelDescriptor?,
        quality: TranscriptionQuality?
    ) {
        record(
            .dictationSucceeded,
            [
                "source": source.rawValue,
                "duration_bucket": duration.rawValue,
                "model_id": TelemetryModelID.of(model, source: source),
                "quality": TelemetryQuality.of(quality, source: source).rawValue,
            ]
        )
    }

    func dictationFailed(
        stage: TelemetryStage,
        reason: TelemetryReason,
        source: TelemetrySource,
        model: LocalModelDescriptor?,
        quality: TranscriptionQuality?
    ) {
        record(
            .dictationFailed,
            [
                "stage": stage.rawValue,
                "reason": reason.rawValue,
                "source": source.rawValue,
                "model_id": TelemetryModelID.of(model, source: source),
                "quality": TelemetryQuality.of(quality, source: source).rawValue,
            ]
        )
    }

    // MARK: - The switch

    /// Turns reporting on or off, and does the one thing the settings copy
    /// promises: a final `telemetry_disabled` event goes out before the switch
    /// takes effect, so the opt-out rate is knowable.
    ///
    /// Both directions rotate the session, so events either side of a toggle
    /// cannot be stitched together. Turning it off also discards whatever was
    /// still queued — an opt-out that silently delivered a backlog would be a
    /// lie.
    func setEnabled(_ enabled: Bool) async {
        if enabled {
            session.rotate()
            preferences.setEnabled(true)
            return
        }
        if preferences.isEnabled {
            enqueue(.telemetryDisabled, [:])
            await drain()
        }
        preferences.setEnabled(false)
        queue.clear()
        session.rotate()
    }

    // MARK: - Delivery

    /// Sends what is queued, in batches of at most ``TelemetryConfig/maxBatch``.
    ///
    /// Fails closed. A rejected batch is dropped, an unavailable one is put back
    /// once and the flush stops — the real retry is the next flush, when the app
    /// is next backgrounded. A network failure must never surface in the
    /// interface: the user did not ask for this feature to work.
    func flush() async {
        guard preferences.isEnabled else {
            queue.clear()
            return
        }
        await drain()
    }

    private func drain() async {
        while !queue.isEmpty {
            let batch = queue.takeBatch()
            guard !batch.isEmpty else { return }
            let delivery = await sink.send(batch)
            stats.attempted(delivery, batchSize: batch.count, at: clock())
            switch delivery {
            case .delivered, .rejected:
                continue
            case .unavailable:
                queue.requeue(batch)
                return
            }
        }
    }

    /// What the "See what's sent" screen renders: the literal JSON that would go
    /// over the wire, nothing summarised or paraphrased.
    ///
    /// Self-enforcing. If someone later adds a field to ``TelemetrySystemProps``
    /// or slips a property into an event, it appears here in front of the user
    /// without anyone remembering to update a description of it.
    func pendingPayload() -> String {
        let pending = queue.all
        guard !pending.isEmpty else { return "" }
        let encoder = TelemetryRecord.encoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return stride(from: 0, to: pending.count, by: TelemetryConfig.maxBatch)
            .compactMap { start -> String? in
                let batch = Array(pending[start..<min(start + TelemetryConfig.maxBatch, pending.count)])
                guard let data = try? encoder.encode(batch) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
            .joined(separator: "\n\n")
    }

    var pendingCount: Int { queue.count }

    /// One line of content-free delivery state for the "See what's sent" screen.
    ///
    /// Answers the question that took two wrong diagnoses to ask properly: did
    /// this event ever get recorded, and did the last send actually succeed?
    var deliveryStatus: String { stats.summary }

    // MARK: - Internals

    private func record(_ event: TelemetryEvent, _ props: [String: String] = [:]) {
        guard preferences.isEnabled else { return }
        enqueue(event, props)
    }

    /// `key` separates milestones that share an event name — one per setup step
    /// — so completing the microphone step does not also mark the keyboard step
    /// as already reported.
    private func recordOnce(
        _ event: TelemetryEvent,
        _ props: [String: String] = [:],
        key: String? = nil
    ) {
        // The enabled check comes first, and the ordering is the whole point.
        // Claiming the milestone before it burns the claim while reporting is
        // off -- and because reporting is off by default and the opt-in is asked
        // at the *end* of setup, `app_first_open` and every
        // `setup_step_completed` would already be spent by the time anyone could
        // say yes. The activation rate this feature exists to measure is
        // `first_dictation_ever / app_first_open`, so a burnt denominator makes
        // it permanently zero.
        //
        // Claiming only while enabled means a milestone fires on its first
        // *observable* occurrence instead, which is the honest denominator:
        // "installs we were allowed to watch", not "installs".
        guard preferences.isEnabled else { return }
        let milestone = [event.rawValue, key].compactMap { $0 }.joined(separator: ":")
        guard preferences.claimMilestone(milestone) else { return }
        enqueue(event, props)
    }

    private func enqueue(_ event: TelemetryEvent, _ props: [String: String]) {
        queue.add(
            TelemetryRecord(
                timestamp: clock(),
                sessionId: session.currentId(),
                eventName: event.rawValue,
                systemProps: systemProps(),
                props: props
            )
        )
        stats.recorded()
        scheduleFlush()
    }

    /// Sends shortly after an event, coalescing anything else in the same
    /// window.
    ///
    /// This is what actually delivers most events. A dictation can complete
    /// while the app is already in the background, so the `scenePhase`
    /// transition that `VocaPhoneApp` flushes on never comes — without this,
    /// those events sit in the queue until the process ends. Superseding the
    /// previous task rather than stacking one per event keeps a burst to a
    /// single request.
    private func scheduleFlush() {
        guard let autoFlushDelay else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: autoFlushDelay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }
}
