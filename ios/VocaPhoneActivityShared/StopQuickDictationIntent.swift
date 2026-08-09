import ActivityKit
import AppIntents
import Foundation

/// Runs from the Live Activity without opening VocaPhone. The App Group write
/// makes the command durable, while the Darwin ping tells the still-running
/// containing app to release its audio engine immediately.
struct StopQuickDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn off Quick Dictation"
    static let description = IntentDescription(
        "Stops VocaPhone standby and releases the microphone."
    )

    func perform() async throws -> some IntentResult {
        KeyboardPreferences.quickDictationEnabled = false
        try? SharedStore.shared.clearQuickDictationAvailability()
        DiagnosticLog.record(.stopQuickDictationRequested)
        VocaPhoneDarwinCenter.post(.stopQuickDictationRequested)

        let content = ActivityContent(
            state: VocaPhoneActivityAttributes.ContentState(
                status: "Quick Dictation off",
                canFinish: false,
                phase: .finished
            ),
            staleDate: nil
        )
        for activity in Activity<VocaPhoneActivityAttributes>.activities {
            await activity.end(content, dismissalPolicy: .immediate)
        }
        return .result()
    }
}
