import Foundation

/// Written by the keyboard extension every time it loads. The containing app
/// cannot ask iOS whether its keyboard is installed, and only a keyboard with
/// Full Access can write into the shared container at all — so the presence of
/// a recent record answers both setup questions at once.
struct KeyboardStatus: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    var lastSeenAt: Date
    var hasFullAccess: Bool

    init(lastSeenAt: Date = Date(), hasFullAccess: Bool) {
        schemaVersion = Self.schemaVersion
        self.lastSeenAt = Self.normalizedTimestamp(lastSeenAt)
        self.hasFullAccess = hasFullAccess
    }

    private static func normalizedTimestamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
