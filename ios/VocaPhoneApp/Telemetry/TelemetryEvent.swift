import Foundation

/// The complete telemetry vocabulary.
///
/// Deliberately finite and content-free, for the same reason ``DiagnosticEvent``
/// is: nothing here accepts a transcript, typed text, audio path, gateway URL,
/// model file path, or bearer token, so private user content cannot reach the
/// network by accident.
///
/// The enforcement is structural rather than a matter of review discipline.
/// Every property value below is an enum, and ``Telemetry`` exposes one typed
/// method per event instead of a generic `track(name:properties:)`. A call site
/// cannot pass a free string because no parameter accepts one.
///
/// ## Why this lives in the app target
///
/// This whole directory is compiled into `VocaPhoneApp` only. The keyboard
/// extension's sources are `VocaPhoneKeyboard` plus `VocaPhoneShared`, so it
/// gets none of it, and its `PrivacyInfo.xcprivacy` keeps an empty
/// `NSPrivacyCollectedDataTypes`. A Full Access keyboard that can open a socket
/// is the scariest thing this product could ship, whatever is actually in the
/// packet — so it cannot.
///
/// The cost is that `insertionSkipped`, the hardest failure in the product to
/// reproduce, is not reported in v1. That is the right trade until the pipeline
/// has a release behind it.
///
/// The raw values are what land in ClickHouse, so treat them as a published
/// schema: add new ones, never rename an existing one. They are held identical
/// to the Kotlin copy in
/// `android/app/src/main/java/com/vocahq/vocaphone/telemetry/TelemetryEvent.kt`
/// by `TelemetryParityTest`, which reads this file from the Android test suite
/// so it runs without an iOS toolchain; a drifted enum is a silently broken
/// funnel rather than a build failure, which is why it is checked at all.
enum TelemetryEvent: String, CaseIterable, Sendable {
    /// Fired once ever, on the first launch after install. The denominator for
    /// every activation ratio, which is the only reason it exists: Aptabase
    /// rotates its anonymous user hash daily (see ``TelemetryConfig``), so
    /// per-user funnels are impossible and counting one-shot milestones is what
    /// replaces them.
    case appFirstOpen = "app_first_open"

    /// Once per step, ever. The setup funnel is the ratio of these to ``appFirstOpen``.
    case setupStepCompleted = "setup_step_completed"

    /// Once ever, when guided setup is finished rather than abandoned.
    case setupFinished = "setup_finished"

    /// Which transcription route the user picked. Repeats: switching back is a signal.
    case sourceSelected = "source_selected"

    /// Whether an on-device model download actually completed, and which one.
    case modelDownloadFinished = "model_download_finished"

    /// Once ever. The single most valuable number in the whole feature: the
    /// share of installs that reach a working transcript at all.
    case firstDictationEver = "first_dictation_ever"

    case dictationSucceeded = "dictation_succeeded"

    case dictationFailed = "dictation_failed"

    /// Sent once, as the last act before reporting is switched off, so the
    /// opt-out rate is knowable. Disclosed in the settings copy: a "we log your
    /// opt-out" that a user discovers by packet capture is much worse than not
    /// knowing the number.
    case telemetryDisabled = "telemetry_disabled"

    /// Fired at most once per install. Guarded by a local flag, never sent twice.
    static let oneShot: Set<TelemetryEvent> = [
        .appFirstOpen, .setupStepCompleted, .setupFinished, .firstDictationEver,
    ]
}

/// The guided-setup steps.
///
/// Deliberately not derived from ``SetupStep`` in `SetupStatus.swift`: that enum
/// is free to be renamed or reordered as the setup screen changes, and this one
/// cannot be, because it is a wire format.
enum TelemetrySetupStep: String, CaseIterable, Sendable {
    case keyboard
    case microphone
    case notifications
    case source
}

/// Where transcription ran. The gateway's address is never part of this.
enum TelemetrySource: String, CaseIterable, Sendable {
    case onDevice = "on_device"
    case gateway
}

/// Which route a session actually ran on, as the one fact about the user's
/// transcription setup that may be reported.
///
/// An extension on `SessionRecord` rather than a member of it, so the telemetry
/// vocabulary stays in this directory and nothing in the shared model has to
/// know this feature exists. A session with no recorded location is reported as
/// the gateway, matching what the app falls back to.
extension SessionRecord {
    var telemetrySource: TelemetrySource {
        processingLocation == .onDevice ? .onDevice : .gateway
    }
}

/// How far a dictation got before it failed, drawn from the timing stages
/// ``DiagnosticEvent`` already records. Knowing a failure happened is nearly
/// useless; knowing it happened at upload rather than insertion is the whole
/// value of the event.
enum TelemetryStage: String, CaseIterable, Sendable {
    case capture
    case upload
    case transcription
    case insertion
}

/// Why it failed. Its own enum rather than a reuse of ``DiagnosticReason`` so
/// the diagnostic log can grow categories without silently widening what is
/// sent over the network.
enum TelemetryReason: String, CaseIterable, Sendable {
    case audio
    case audioFocusLost = "audio_focus_lost"
    case audioSilenced = "audio_silenced"
    case audioCaptureLost = "audio_capture_lost"
    case gatewayUnreachable = "gateway_unreachable"
    case gatewayRejected = "gateway_rejected"
    case engineNotReady = "engine_not_ready"
    case modelMissing = "model_missing"
    case transcriptEmpty = "transcript_empty"
    case targetFieldChanged = "target_field_changed"
    case insertionRejected = "insertion_rejected"
    case permission
    case unknown
}

/// Recording length, bucketed.
///
/// Never the exact duration and never a character count: both are
/// content-length side channels. Buckets answer the one question worth asking —
/// whether `AppConfiguration.maximumRecordingSeconds` is cutting real
/// dictations short — and nothing else.
enum TelemetryDurationBucket: String, CaseIterable, Sendable {
    case under10s = "under_10s"
    case tenTo30s = "10_30s"
    case thirtyTo60s = "30_60s"
    case over60s = "over_60s"

    static func of(_ seconds: TimeInterval) -> TelemetryDurationBucket {
        switch seconds {
        case ..<10: .under10s
        case ..<30: .tenTo30s
        case ..<60: .thirtyTo60s
        default: .over60s
        }
    }
}

/// How much decoding work the on-device engines were allowed to spend.
///
/// Its own enum rather than a reuse of ``TranscriptionQuality`` for the same
/// reason ``TelemetryReason`` is separate from the diagnostic categories: that
/// type is a user-facing setting and is free to grow a case or rename one,
/// while this is a wire format that cannot. It also needs a value the setting
/// has no business having — ``notApplicable``, for the gateway route, which
/// decides its own decoding and would be misdescribed by whatever happens to be
/// selected locally.
enum TelemetryQuality: String, CaseIterable, Sendable {
    case fast
    case balanced
    case accurate
    /// Transcription did not run on this iPhone, so the local accuracy setting
    /// did not apply to it.
    case notApplicable = "not_applicable"

    static func of(
        _ quality: TranscriptionQuality?,
        source: TelemetrySource
    ) -> TelemetryQuality {
        guard source == .onDevice, let quality else { return .notApplicable }
        return switch quality {
        case .fast: .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
    }
}

enum TelemetryDownloadOutcome: String, CaseIterable, Sendable {
    case completed
    case failed
    case cancelled
    /// The file downloaded but its SHA-256 did not match the pinned digest.
    case integrityFailed = "integrity_failed"
}

/// Which model a dictation actually ran on.
///
/// `model_download_finished` already answers "which models get downloaded",
/// which is a different and much weaker question: a download is a one-time act
/// of optimism, and someone can fetch three models, use one, and go back to the
/// gateway. Only the dictation events can say whether a performance fix landed
/// on the model people are really dictating with.
///
/// Not an enum, because the catalog is data rather than vocabulary and gains
/// entries every release. The safety comes from pinning instead: anything the
/// shipped ``LocalModelCatalog`` does not contain is reported as ``unknown``,
/// so a sideloaded directory name or a stale identifier cannot reach the
/// network even though the value begins life as a string.
enum TelemetryModelID {
    /// Transcription ran on the user's own gateway, which never tells the app
    /// which model it loaded — and must not be asked, since that answer
    /// describes a machine rather than this install. A fixed value rather than
    /// an omitted property, so the column stays groupable instead of ragged.
    static let gateway = "gateway"

    /// A model the shipped catalog does not contain: a sideloaded directory, or
    /// an entry withdrawn in a later release.
    static let unknown = "unknown"

    /// Pins a descriptor to the shipped catalog. Everything that reports a model
    /// goes through here, so there is one place to audit rather than two.
    static func pinned(_ descriptor: LocalModelDescriptor?) -> String {
        guard let descriptor, LocalModelCatalog.all.contains(where: { $0.id == descriptor.id })
        else { return unknown }
        return descriptor.id
    }

    /// What a dictation reports. Gateway sessions name the gateway rather than
    /// whichever model happens to be selected on this iPhone: attributing a
    /// session to a model that never touched it is worse than reporting nothing.
    static func of(_ descriptor: LocalModelDescriptor?, source: TelemetrySource) -> String {
        source == .onDevice ? pinned(descriptor) : gateway
    }
}
