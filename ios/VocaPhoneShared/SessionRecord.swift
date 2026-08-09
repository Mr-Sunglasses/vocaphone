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

    private static let allowedTransitions: [SessionState: Set<SessionState>] = [
        .idle: [.launchingApp, .canceled],
        .launchingApp: [.awaitingReturn, .recording, .permissionDenied, .canceled],
        .awaitingReturn: [.recording, .permissionDenied, .canceled],
        .recording: [.finalizing, .canceled, .expired],
        .finalizing: [.uploading, .uploadFailedRecoverable, .canceled],
        .uploading: [.transcribing, .readyToInsert, .serverUnavailable, .uploadFailedRecoverable, .canceled],
        .transcribing: [
            .readyToInsert, .transcriptionFailedRecoverable,
            .transcriptionFailedPermanent, .serverUnavailable,
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
