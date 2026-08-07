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
