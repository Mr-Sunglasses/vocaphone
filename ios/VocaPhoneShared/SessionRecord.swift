import Foundation

enum SessionState: String, Codable, CaseIterable, Sendable {
    case idle
    case launchingApp
    case awaitingReturn
    case recording
    case finalizing
    case uploading
    case transcribing
    case readyToInsert
    case inserting
    case inserted
    case completed
    case canceled
    case permissionDenied
    case serverUnavailable
    case uploadFailedRecoverable
    case transcriptionFailedRecoverable
    case transcriptionFailedPermanent
    case targetContextChanged
    case expired

    /// What the state is called on screen. The raw values are wire and storage
    /// identifiers, and the main screen was showing them to the reader verbatim
    /// — "uploadFailedRecoverable" is a case name, not a sentence.
    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .launchingApp: "Opening vocaphone"
        case .awaitingReturn: "Waiting to return"
        case .recording: "Recording"
        case .finalizing: "Finishing"
        case .uploading: "Uploading"
        case .transcribing: "Transcribing"
        case .readyToInsert: "Ready to insert"
        case .inserting: "Inserting"
        case .inserted: "Inserted"
        case .completed: "Done"
        case .canceled: "Canceled"
        case .permissionDenied: "Microphone access denied"
        case .serverUnavailable: "Gateway unreachable"
        case .uploadFailedRecoverable: "Upload failed, can retry"
        case .transcriptionFailedRecoverable: "Transcription failed, can retry"
        case .transcriptionFailedPermanent: "Transcription failed"
        case .targetContextChanged: "Text field changed"
        case .expired: "Expired"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .canceled, .permissionDenied, .transcriptionFailedPermanent,
             .expired:
            true
        default:
            false
        }
    }
}

/// Where a session's speech-to-text actually runs.
///
/// Written by the containing app when it claims a hand-off, because that is the
/// only process that knows which route is selected *and* the only one that can
/// resolve it before any audio moves. The keyboard and the Live Activity read
/// it so that all three surfaces name the same place.
///
/// There is no `unknown` case on purpose. An absent value is a real state — a
/// record written before this field existed, or a session interrupted before the
/// app claimed it — and it is answered with neutral wording rather than a guess.
enum SessionProcessingLocation: String, Codable, Sendable {
    /// A downloaded speech-to-text model running on this iPhone.
    case onDevice
    /// The self-hosted gateway the user configured. Deliberately not "your Mac":
    /// a gateway may be a Linux box, a home server, or a VPS.
    case gateway
}

struct SessionFailure: Codable, Equatable, Sendable {
    let code: String
    let message: String
    let recoverable: Bool
}

struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    var id: UUID { sessionID }
    let schemaVersion: Int
    let sessionID: UUID
    var revision: Int
    var state: SessionState
    let createdAt: Date
    var updatedAt: Date
    var sourceDocumentID: String?
    var language: String
    var style: String
    var meterLevel: Float
    var localAudioReference: String?
    var serverJobID: String?
    var transcript: String?
    var error: SessionFailure?
    /// Set when the keyboard was hosted by vocaphone itself. Such a session has
    /// no other app to return to, so the hand-off guidance must be suppressed.
    /// Optional so records written before this field still decode.
    var startedInContainingApp: Bool?
    /// When the containing app took ownership of a hand-off, written before the
    /// microphone is warm. The keyboard's launch fallback waits on this: warming
    /// the graph can take longer than the fallback window — a first on-device
    /// model load, or a microphone another app is still releasing — and opening
    /// vocaphone anyway pulls the user out of the app they are typing in for a
    /// Quick Dictation that was about to succeed. Optional so records written
    /// before this field still decode.
    var claimedAt: Date?
    /// Where transcription runs for this session, resolved by the containing app
    /// when it claims the request. Optional so records written before this field
    /// still decode — and so that an interrupted session says "Transcribing"
    /// rather than naming a route nobody confirmed. See
    /// ``SessionProcessingLocation``.
    var processingLocation: SessionProcessingLocation?

    init(
        sessionID: UUID = UUID(),
        state: SessionState = .idle,
        sourceDocumentID: String? = nil,
        language: String = "auto",
        style: String = WritingStyle.casual.rawValue,
        now: Date = Date()
    ) {
        let timestamp = Self.normalizedTimestamp(now)
        schemaVersion = Self.schemaVersion
        self.sessionID = sessionID
        revision = 0
        self.state = state
        createdAt = timestamp
        updatedAt = timestamp
        self.sourceDocumentID = sourceDocumentID
        self.language = language
        self.style = style
        meterLevel = 0
        startedInContainingApp = nil
        claimedAt = nil
        processingLocation = nil
    }

    mutating func transition(to next: SessionState, now: Date = Date()) throws {
        guard Self.allowedTransitions[state, default: []].contains(next) else {
            throw SessionTransitionError.invalid(from: state, to: next)
        }
        state = next
        revision += 1
        updatedAt = Self.normalizedTimestamp(now)
        if next != .recording {
            meterLevel = 0
        }
    }

    mutating func updateMeter(_ level: Float, now: Date = Date()) {
        guard state == .recording else { return }
        meterLevel = min(max(level, 0), 1)
        revision += 1
        updatedAt = Self.normalizedTimestamp(now)
    }

    private static let retryableFailures: Set<SessionState> = [
        .serverUnavailable, .uploadFailedRecoverable, .transcriptionFailedRecoverable,
    ]

    /// Every waiting state can also expire. Each of them is waiting on another
    /// process that can silently never answer — a host app that swallowed the
    /// hand-off, a containing app iOS killed mid-recording, a gateway that
    /// stopped replying — and without a way out the record stays non-terminal
    /// for the life of the install. See `SessionExpiryPolicy`.
    private static let allowedTransitions: [SessionState: Set<SessionState>] = [
        .idle: [.launchingApp, .canceled],
        .launchingApp: [.awaitingReturn, .recording, .permissionDenied, .canceled, .expired],
        .awaitingReturn: [.recording, .permissionDenied, .canceled, .expired],
        .recording: [.finalizing, .canceled, .expired],
        // A capture can be known unusable before anything is ever sent: a
        // microphone another app silenced yields a file that no amount of
        // retrying will turn into a transcript.
        .finalizing: [
            .uploading, .uploadFailedRecoverable, .transcriptionFailedPermanent, .canceled,
            .expired,
        ],
        .uploading: [
            .transcribing, .readyToInsert, .serverUnavailable, .uploadFailedRecoverable,
            .canceled, .expired,
        ],
        .transcribing: [
            .readyToInsert, .transcriptionFailedRecoverable,
            .transcriptionFailedPermanent, .serverUnavailable, .canceled, .expired,
        ],
        .readyToInsert: [.inserting, .targetContextChanged, .canceled, .expired],
        // The transcript survives a detour into another text field. Returning to
        // the originating document restores the pending insertion instead of
        // discarding work the user already spoke.
        .targetContextChanged: [.readyToInsert, .canceled, .expired],
        .inserting: [.inserted, .readyToInsert],
        .inserted: [.completed],
        .serverUnavailable: [.uploading, .canceled, .expired],
        .uploadFailedRecoverable: [.uploading, .canceled, .expired],
        .transcriptionFailedRecoverable: [.transcribing, .uploading, .canceled, .expired],
    ]

    var canRetry: Bool {
        Self.retryableFailures.contains(state)
    }

    private static func normalizedTimestamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

enum SessionTransitionError: Error, Equatable {
    case invalid(from: SessionState, to: SessionState)
}

/// How long a session may sit in one state before every process should stop
/// treating it as live.
///
/// A session that nothing retires stays non-terminal forever, and the keyboard
/// adopts the newest non-terminal session on *every* appearance in *every* app.
/// That is how a hand-off the host app silently refused becomes a permanent
/// "Opening vocaphone" bar, and how a transcript abandoned yesterday gets
/// auto-inserted into an unrelated field today.
///
/// The windows are generous on purpose: expiring is a watchdog for a process
/// that is gone, never a deadline for a slow one.
enum SessionExpiryPolicy {
    /// The containing app claims a hand-off within seconds. Two minutes still
    /// covers a cold launch behind Face ID and a first on-device model load.
    static let handoffWindow: TimeInterval = 120
    /// Capture is hard-capped by `maximumRecordingSeconds`, so anything past
    /// that plus a wide margin means the recorder is gone, not slow.
    static let captureWindow: TimeInterval = AppConfiguration.maximumRecordingSeconds + 120
    /// Upload and transcription run on the user's own gateway or on device.
    static let processingWindow: TimeInterval = 10 * 60
    /// A transcript waiting for a tap stays useful for a while, but not for the
    /// rest of the install — it is offered by whichever field is focused next.
    static let pendingUserActionWindow: TimeInterval = 60 * 60

    static func window(for state: SessionState) -> TimeInterval? {
        switch state {
        case .launchingApp, .awaitingReturn:
            handoffWindow
        case .recording:
            captureWindow
        case .finalizing, .uploading, .transcribing:
            processingWindow
        case .readyToInsert, .targetContextChanged, .serverUnavailable,
             .uploadFailedRecoverable, .transcriptionFailedRecoverable:
            pendingUserActionWindow
        // `idle`, `inserting` and `inserted` last microseconds inside a single
        // process, and the terminal states need no watchdog at all.
        default:
            nil
        }
    }

    static func isStale(_ record: SessionRecord, now: Date = Date()) -> Bool {
        guard let window = window(for: record.state) else { return false }
        return now.timeIntervalSince(record.updatedAt) > window
    }

    /// Retires a stale session durably, so the other process learns about it
    /// through the shared record rather than each one keeping its own timer.
    /// Returns the expired record, or nil when the session is still live.
    @discardableResult
    static func expireIfStale(
        _ record: SessionRecord,
        in store: SharedStore,
        now: Date = Date()
    ) -> SessionRecord? {
        guard isStale(record, now: now) else { return nil }
        var expiring = record
        do {
            try expiring.transition(to: .expired, now: now)
            try store.save(expiring)
        } catch {
            // A state with no expiry path keeps whatever recovery it offers.
            return nil
        }
        DiagnosticLog.record(.sessionExpired, metadata: .state(record.state))
        return expiring
    }
}

/// Polling is only a recovery path for a dropped Darwin notification. Keep it
/// responsive while the user is waiting for Finish or insertion, then relax it
/// for states that require an explicit user action rather than background work.
enum SessionPollingPolicy {
    static let responsiveInterval: TimeInterval = 0.25
    static let relaxedInterval: TimeInterval = 1.5

    static func interval(for state: SessionState?) -> TimeInterval? {
        guard let state, !state.isTerminal else { return nil }
        switch state {
        case .recording, .finalizing, .uploading, .transcribing:
            return responsiveInterval
        default:
            return relaxedInterval
        }
    }
}

/// A recent health response is authoritative enough to avoid opening a socket
/// that the selected model explicitly cannot use. Unknown or stale capability
/// data still negotiates normally, so changing models in the gateway recovers
/// without requiring the app to be re-paired.
enum GatewayStreamingPolicy {
    static let capabilityFreshnessInterval: TimeInterval = 5 * 60

    static func shouldAttemptStreaming(
        supported: Bool?,
        checkedAt: Date?,
        cachedBaseURL: String?,
        currentBaseURL: URL,
        now: Date = Date()
    ) -> Bool {
        guard let supported,
              let checkedAt,
              cachedBaseURL == currentBaseURL.absoluteString,
              now.timeIntervalSince(checkedAt) >= 0,
              now.timeIntervalSince(checkedAt) <= capabilityFreshnessInterval
        else { return true }
        return supported
    }
}
