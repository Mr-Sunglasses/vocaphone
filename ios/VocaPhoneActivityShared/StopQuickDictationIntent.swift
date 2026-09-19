import ActivityKit
import AppIntents
import Foundation

/// Runs from the Live Activity without opening VocaPhone. The App Group write
/// makes the command durable, while the Darwin ping tells the still-running
/// containing app to release its audio engine immediately.
///
/// This is a pause, not a settings change. Somebody reaching for it wants the
/// microphone released now — from a button that offers no way to undo itself —
/// not to be sent hunting through Settings the next time they dictate. The next
/// launch of vocaphone clears the pause and arms a fresh window.
struct StopQuickDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause Quick Dictation"
    static let description = IntentDescription(
        "Ends this VocaPhone standby window and releases the microphone. Reopening VocaPhone starts a new one."
    )

    func perform() async throws -> some IntentResult {
        KeyboardPreferences.quickDictationPausedUntilRelaunch = true
        try? SharedStore.shared.clearQuickDictationAvailability()
        DiagnosticLog.record(.stopQuickDictationRequested)
        VocaPhoneDarwinCenter.post(.stopQuickDictationRequested)

        let content = ActivityContent(
            state: VocaPhoneActivityAttributes.ContentState(
                status: "Quick Dictation paused",
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
