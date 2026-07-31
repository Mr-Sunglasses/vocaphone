import Foundation

struct QuickDictationAvailability: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let activatedAt: Date
    let expiresAt: Date

    init(activatedAt: Date = Date(), expiresAt: Date) {
        schemaVersion = Self.schemaVersion
        self.activatedAt = Self.normalizedTimestamp(activatedAt)
        self.expiresAt = Self.normalizedTimestamp(expiresAt)
    }

    func isReady(at date: Date = Date()) -> Bool {
        schemaVersion == Self.schemaVersion && expiresAt > date
    }

    private static func normalizedTimestamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
