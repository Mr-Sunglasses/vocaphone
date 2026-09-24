import UIKit

/// Holds the app awake for the few seconds iOS grants a backgrounded process to
/// finish what it started. Ended explicitly by the owner, or by iOS through the
/// expiration handler when that time runs out — whichever comes first; the
/// second call is a no-op.
final class BackgroundAssertion: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        self.name = name
    }

    @MainActor
    func begin() {
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: name
        ) { [weak self] in
            self?.end()
        }
        lock.lock()
        self.identifier = identifier
        lock.unlock()
    }

    func end() {
        lock.lock()
        let identifier = self.identifier
        self.identifier = .invalid
        lock.unlock()
        guard identifier != .invalid else { return }
        // Synchronously when possible: the expiration handler runs on the main
        // thread, and iOS kills an app whose task is still open when that
        // handler returns. A hop through a Task would end it a moment too late.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                UIApplication.shared.endBackgroundTask(identifier)
            }
        } else {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
    }
}
