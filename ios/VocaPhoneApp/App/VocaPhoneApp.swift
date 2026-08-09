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
                .onAppear { KeyboardPreferences.containingAppIsForeground = true }
                .onChange(of: scenePhase) { _, phase in
                    KeyboardPreferences.containingAppIsForeground = phase == .active
                    guard phase == .active else { return }
                    Task {
                        await coordinator.recoverRecentSession()
                        coordinator.prepareQuickDictationIfEnabled()
                    }
                }
        }
    }
}
