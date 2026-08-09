import Foundation

struct QuickDictationAvailability: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let heartbeatMaximumAge: TimeInterval = 6

    let schemaVersion: Int
    let activatedAt: Date
    let expiresAt: Date
    let heartbeatAt: Date?

    init(
        activatedAt: Date = Date(),
        expiresAt: Date,
        heartbeatAt: Date? = nil
    ) {
        schemaVersion = Self.schemaVersion
        self.activatedAt = Self.normalizedTimestamp(activatedAt)
        self.expiresAt = Self.normalizedTimestamp(expiresAt)
        self.heartbeatAt = Self.normalizedTimestamp(heartbeatAt ?? activatedAt)
    }

    func isReady(at date: Date = Date()) -> Bool {
        guard schemaVersion == Self.schemaVersion,
              expiresAt > date,
              let heartbeatAt
        else { return false }
        let heartbeatAge = date.timeIntervalSince(heartbeatAt)
        return heartbeatAge >= -1 && heartbeatAge <= Self.heartbeatMaximumAge
    }

    func refreshingHeartbeat(at date: Date = Date()) -> QuickDictationAvailability {
        QuickDictationAvailability(
            activatedAt: activatedAt,
            expiresAt: expiresAt,
            heartbeatAt: date
        )
    }

    /// A keyboard request and a standby re-arm can cross in separate processes.
    /// The tiny grace window accepts that in-flight request without adopting an
    /// older abandoned session from before Quick Dictation was available.
    func acceptsRequest(createdAt: Date, grace: TimeInterval = 2) -> Bool {
        createdAt >= activatedAt.addingTimeInterval(-grace) && createdAt < expiresAt
    }

    private static func normalizedTimestamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
