import SwiftUI

@main
struct VocaPhoneApp: App {
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
