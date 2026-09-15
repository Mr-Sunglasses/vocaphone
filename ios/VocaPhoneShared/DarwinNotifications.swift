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
    /// The keyboard's VocaPhone switch turned off. Unlike the Live Activity's
    /// stop, this is not a Quick Dictation pause: it ends the running app's
    /// window the way the app switcher would, and changes no preference.
    case closeVocaPhoneRequested = "com.vocahq.vocaphone.close-requested"
    /// The keyboard came up with almost no room left. It cannot free what is
    /// holding the memory — that is the app's loaded speech model, in another
    /// process — so it says so, and the app answers by letting go.
    case keyboardLowOnMemory = "com.vocahq.vocaphone.keyboard-low-memory"
    /// The keyboard ran, and could not reach the shared container.
    ///
    /// The exception to the rule above: this one carries no durable record to
    /// reread, because a keyboard without Full Access cannot write one. That is
    /// precisely what it reports. Darwin notifications are name-only IPC and
    /// are not gated by the App Group, so they are the single channel a
    /// keyboard in that state still has — without it, "Full Access is off" and
    /// "you have not opened the keyboard yet" are the same silence, and guided
    /// setup can only show a spinner and hope.
    case keyboardLacksFullAccess = "com.vocahq.vocaphone.keyboard-no-full-access"
    /// The keyboard wrote ``KeyboardPreferences/hasCompletedKeyboardPractice``.
    ///
    /// App Group `UserDefaults` does not reliably wake the containing app, so
    /// guided setup rereads the durable proof after this ping — including the
    /// marker file that survives the suite cache.
    case keyboardPracticeCompleted = "com.vocahq.vocaphone.keyboard-practice-completed"
    /// "Are you on screen right now?", asked by Enable keyboard.
    ///
    /// The keyboard republishes its status only when it *appears*, throttled so
    /// that flicking between keyboards is not a stream of file writes. A
    /// keyboard that is already up when the page opens therefore never writes
    /// again, and a page waiting for a fresh write waits forever. This asks for
    /// one, and only a running extension can answer.
    case keyboardStatusRequested = "com.vocahq.vocaphone.keyboard-status-requested"

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

extension Notification.Name {
    /// Local bridge for ``VocaPhoneDarwinNotification/keyboardPracticeCompleted``.
    /// Darwin itself is not a `NotificationCenter` name, and SwiftUI views
    /// cannot mutate `@AppStorage` from the CF callback.
    static let vocaKeyboardPracticeCompleted = Notification.Name(
        "com.vocahq.vocaphone.keyboard-practice-completed.local"
    )
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
