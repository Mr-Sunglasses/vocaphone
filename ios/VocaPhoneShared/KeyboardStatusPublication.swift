import Foundation

/// Decides whether the keyboard should refresh its Full Access proof.
///
/// iOS can keep a keyboard extension alive while the user changes Allow Full
/// Access in Settings. A repeated appearance with the same value can be
/// throttled, but a changed value must reach guided setup immediately.
enum KeyboardStatusPublication {
    static func shouldPublish(
        lastPublishedAt: Date?,
        lastPublishedFullAccess: Bool?,
        fullAccess: Bool,
        now: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let lastPublishedAt else { return true }
        guard lastPublishedFullAccess == fullAccess else { return true }
        return now.timeIntervalSince(lastPublishedAt) >= minimumInterval
    }
}
