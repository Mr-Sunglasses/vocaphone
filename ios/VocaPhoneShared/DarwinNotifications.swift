import CoreFoundation
import Foundation

/// Cross-process wake-up signals shared by the containing app, keyboard, and
/// Live Activity extension. Darwin notifications intentionally carry no data;
/// every receiver rereads the durable App Group record after the ping.
enum VocaPhoneDarwinNotification: String, Sendable {
    case sessionChanged = "com.vocahq.vocaphone.session-changed"
    case keyboardStatusChanged = "com.vocahq.vocaphone.keyboard-status-changed"
    case quickDictationChanged = "com.vocahq.vocaphone.quick-dictation-changed"
    case stopQuickDictationRequested = "com.vocahq.vocaphone.stop-quick-dictation"

    fileprivate var name: CFNotificationName {
        CFNotificationName(rawValue as CFString)
    }
}

/// Owns one Darwin observer. Keeping observations token-based allows multiple
/// listeners for the same notification without one process-global callback
/// silently replacing another.
final class VocaPhoneDarwinObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var context: UnsafeMutableRawPointer?
    private let name: CFNotificationName

    fileprivate init(
        notification: VocaPhoneDarwinNotification,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        name = notification.name
        let context = DarwinCallbackRegistry.shared.insert(
            queue: queue,
            handler: handler
        )
        self.context = context
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            context,
            vocaPhoneDarwinCallback,
            notification.name.rawValue,
            nil,
            .deliverImmediately
        )
    }

    func invalidate() {
        lock.lock()
        guard let context else {
            lock.unlock()
            return
        }
        self.context = nil
        lock.unlock()

        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            context,
            name,
            nil
        )
        DarwinCallbackRegistry.shared.remove(context: context)
    }

    deinit {
        invalidate()
    }
}

enum VocaPhoneDarwinCenter {
    static func post(_ notification: VocaPhoneDarwinNotification) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            notification.name,
            nil,
            nil,
            true
        )
    }

    @discardableResult
    static func observe(
        _ notification: VocaPhoneDarwinNotification,
        queue: DispatchQueue = .main,
        handler: @escaping @Sendable () -> Void
    ) -> VocaPhoneDarwinObservation {
        VocaPhoneDarwinObservation(
            notification: notification,
            queue: queue,
            handler: handler
        )
    }
}

private let vocaPhoneDarwinCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    DarwinCallbackRegistry.shared.deliver(context: observer)
}

private final class DarwinCallbackRegistry: @unchecked Sendable {
    struct Entry: @unchecked Sendable {
        let queue: DispatchQueue
        let handler: @Sendable () -> Void
    }

    static let shared = DarwinCallbackRegistry()

    private let lock = NSLock()
    private var entries: [UInt: Entry] = [:]
    private var nextIdentifier: UInt = 1

    @discardableResult
    func insert(
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> UnsafeMutableRawPointer {
        lock.lock()
        let identifier = nextIdentifier
        // Opaque observer values are never dereferenced. Monotonic identifiers
        // avoid an old in-flight callback ever matching a newer observation.
        nextIdentifier &+= 1
        if nextIdentifier == 0 { nextIdentifier = 1 }
        entries[identifier] = Entry(queue: queue, handler: handler)
        lock.unlock()
        return UnsafeMutableRawPointer(bitPattern: identifier)!
    }

    func remove(context: UnsafeMutableRawPointer) {
        lock.lock()
        entries.removeValue(forKey: UInt(bitPattern: context))
        lock.unlock()
    }

    func deliver(context: UnsafeMutableRawPointer) {
        lock.lock()
        let entry = entries[UInt(bitPattern: context)]
        lock.unlock()
        guard let entry else { return }
        entry.queue.async(execute: entry.handler)
    }
}
