import ActivityKit
import Foundation

struct VocaPhoneActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case standby
            case recording
            case processing
            case finished
        }

        var status: String
        var canFinish: Bool
        /// These values change when Quick Dictation moves from standby into a
        /// real recording, so they belong in the mutable content state rather
        /// than the activity's immutable attributes.
        var phase: Phase?
        var sessionID: String?
        var startedAt: Date?

        init(
            status: String,
            canFinish: Bool,
            phase: Phase? = nil,
            sessionID: String? = nil,
            startedAt: Date? = nil
        ) {
            self.status = status
            self.canFinish = canFinish
            self.phase = phase
            self.sessionID = sessionID
            self.startedAt = startedAt
        }

        var effectivePhase: Phase {
            phase ?? (canFinish ? .recording : .processing)
        }
    }

    let sessionID: String
    let startedAt: Date
}
