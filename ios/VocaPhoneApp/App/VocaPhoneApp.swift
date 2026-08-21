import SwiftUI
import UIKit

/// UIKit delivers the completion handler for a background `URLSession` here.
/// The session delegate calls it only after all queued download events have
/// been handed back to the app.
final class ModelDownloadBackgroundEvents: @unchecked Sendable {
    static let shared = ModelDownloadBackgroundEvents()

    private final class HandlerBox: @unchecked Sendable {
        let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }
    }

    private let lock = NSLock()
    private var handlers: [String: HandlerBox] = [:]

    private init() {}

    func register(identifier: String, completion: @escaping () -> Void) {
        lock.lock()
        handlers[identifier] = HandlerBox(completion)
        lock.unlock()
    }

    func finish(identifier: String) {
        lock.lock()
        let handler = handlers.removeValue(forKey: identifier)
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async {
            handler.handler()
        }
    }
}

final class VocaPhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == LocalModelManager.backgroundDownloadSessionIdentifier else {
            completionHandler()
            return
        }
        ModelDownloadBackgroundEvents.shared.register(
            identifier: identifier,
            completion: completionHandler
        )
    }
}

@main
struct VocaPhoneApp: App {
    @UIApplicationDelegateAdaptor(VocaPhoneAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = RecordingCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
                .tint(.brand)
                .onOpenURL { coordinator.handleDeepLink($0) }
                .onAppear {
                    KeyboardPreferences.containingAppIsForeground = true
                    Telemetry.shared.appFirstOpen()
                }
                .onChange(of: scenePhase) { _, phase in
                    KeyboardPreferences.containingAppIsForeground = phase == .active
                    guard phase == .active else {
                        // The queue is in memory and does not survive the
                        // process, so backgrounding is the only moment a flush
                        // reliably has something to send. A deferred background
                        // task would usually wake to an empty queue.
                        Task { await Telemetry.shared.flush() }
                        return
                    }
                    Task {
                        await coordinator.recoverRecentSession()
                        coordinator.prepareQuickDictationIfEnabled()
                    }
                }
        }
    }
}
