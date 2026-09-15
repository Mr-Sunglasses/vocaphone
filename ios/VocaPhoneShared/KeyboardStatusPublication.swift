import Foundation

/// Decides whether the keyboard should test its Full Access again.
///
/// The test is the App Group write itself, not `hasFullAccess`: reaching the
/// shared container *is* Full Access, and it answers correctly from the moment
/// the process starts, where `hasFullAccess` is read through a host connection
/// that is not up yet in `viewDidLoad` or `viewWillAppear`.
///
/// Changing Allow Full Access terminates the extension, so a changed answer
/// always arrives on a fresh instance with no history — nothing here has to
/// notice a change inside one instance.
enum KeyboardStatusPublication {
    /// - Parameters:
    ///   - lastReachedContainer: whether the last test's write succeeded.
    ///   - forced: the app asked (a setup page is waiting on an answer), as
    ///     opposed to the keyboard simply appearing again.
    ///   - minimumInterval: how long a successful proof stays good enough to
    ///     skip a mere reappearance.
    ///   - minimumGap: the floor under everything, asks included.
    static func shouldPublish(
        lastPublishedAt: Date?,
        lastReachedContainer: Bool?,
        forced: Bool,
        now: Date,
        minimumInterval: TimeInterval,
        minimumGap: TimeInterval
    ) -> Bool {
        guard let lastPublishedAt else { return true }
        let elapsed = now.timeIntervalSince(lastPublishedAt)
        // Setup pages ask several times a second while they wait. Answering
        // each with a file write on the extension's main thread is what made
        // the keyboard stutter as it slid in.
        if elapsed < minimumGap { return false }
        if forced { return true }
        // A fresh proof has nothing new to tell a reappearance. A failed one
        // is re-tested every time: it costs nothing, and "still off" is the
        // report a setup page may be waiting on.
        if lastReachedContainer == true, elapsed < minimumInterval { return false }
        return true
    }
}
