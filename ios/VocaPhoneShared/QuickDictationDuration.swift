import Foundation

/// How long a Quick Dictation standby window lasts once the app arms it.
///
/// Standby is a real, running microphone: it is bounded so a user who forgets
/// about it does not carry an armed input around all day. The choice exists
/// because the right bound is personal — someone dictating in bursts across an
/// afternoon pays the app-switch tax over and over at ten minutes, while
/// someone who dictates twice a week wants the shortest window that works.
enum QuickDictationDuration: String, CaseIterable, Codable, Identifiable, Sendable {
    case tenMinutes
    case twentyMinutes
    /// No deadline: standby is re-leased for as long as the app is alive, and
    /// ends when the user force-quits vocaphone (or iOS reclaims the process).
    case untilAppCloses

    var id: String { rawValue }

    /// The window a fresh arming gets. ``untilAppCloses`` takes a short lease
    /// that the standby watcher keeps renewing, so a process that dies without
    /// running its teardown leaves a marker that expires on its own rather than
    /// one that claims the microphone is ready forever.
    var leaseSeconds: TimeInterval {
        switch self {
        case .tenMinutes: 10 * 60
        case .twentyMinutes: 20 * 60
        case .untilAppCloses: 5 * 60
        }
    }

    /// Whether the watcher pushes the deadline forward on every heartbeat.
    var renewsLease: Bool { self == .untilAppCloses }

    /// The expiry to write for a window armed at `date`.
    func expiry(from date: Date) -> Date {
        date.addingTimeInterval(leaseSeconds)
    }

    /// Settings row title.
    var displayName: String {
        switch self {
        case .tenMinutes: "10 minutes"
        case .twentyMinutes: "20 minutes"
        case .untilAppCloses: "Until I close vocaphone"
        }
    }

    /// Completes "Quick Dictation is on standby …" on the home card.
    ///
    /// A renewing window is given no clock time on purpose: its deadline moves
    /// every couple of seconds, so any time printed here would be a number the
    /// user could watch change for no reason. It names the exit instead.
    func standbyDescription(expiringAt expiresAt: Date) -> String {
        switch self {
        case .tenMinutes, .twentyMinutes:
            "until \(expiresAt.formatted(date: .omitted, time: .shortened))"
        case .untilAppCloses:
            "until you close vocaphone"
        }
    }

    var settingsFooter: String {
        let window: String
        switch self {
        case .tenMinutes: window = "for up to 10 minutes"
        case .twentyMinutes: window = "for up to 20 minutes"
        case .untilAppCloses: window = "until you close vocaphone"
        }
        return "After vocaphone gets microphone access, it keeps an active background "
            + "input \(window) so Dictate can start without leaving the app you are in. "
            + "Standby audio is discarded and never saved or uploaded. The orange "
            + "microphone indicator stays visible while it is on. Pausing from the "
            + "Dynamic Island ends only the current window — reopening vocaphone arms "
            + "a new one, and this switch stays on."
    }
}
