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

    /// A heartbeat that also pushes the deadline out, for a window the user
    /// asked to last as long as the app does. The lease still exists — a
    /// process killed between heartbeats leaves a marker that expires by
    /// itself — it is just continuously renewed while the app is alive.
    func renewingLease(
        _ duration: QuickDictationDuration,
        at date: Date = Date()
    ) -> QuickDictationAvailability {
        guard duration.renewsLease else { return refreshingHeartbeat(at: date) }
        return QuickDictationAvailability(
            activatedAt: activatedAt,
            expiresAt: duration.expiry(from: date),
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
