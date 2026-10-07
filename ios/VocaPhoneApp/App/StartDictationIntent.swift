import AppIntents
import Foundation

/// "Start dictation", for Shortcuts, the Action button and Siri.
///
/// The plumbing already existed behind the `vocaphone://dictate` URL scheme; all
/// this adds is a name the system can offer. It deliberately opens the app:
/// recording needs the microphone, an iOS keyboard extension cannot have it, and
/// an intent that claimed to record without foregrounding the app would be
/// promising something the platform does not allow.
struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start dictation"
    static let description = IntentDescription(
        """
        Opens vocaphone and starts recording. Audio is transcribed on this \
        device or on the gateway you configured.
        """
    )

    /// Recording is a foreground activity here, and saying so is the honest
    /// version of a Shortcuts action that would otherwise appear to work from
    /// the Lock Screen and quietly do nothing.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // A fresh session, written where the app's own deep-link handler looks
        // for it — the same path the keyboard uses, so there is one way in.
        //
        // Its own origin, not the microphone test's: the test's transcript
        // goes nowhere, so the keyboard ignores it, no Live Activity starts and
        // the result reads "Your gateway is working end to end". A dictation
        // from the Action button is meant for the next field the user opens.
        var record = SessionRecord(
            sourceDocumentID: SessionOrigin.shortcut,
            language: KeyboardPreferences.effectiveTranscriptionLanguage.rawValue,
            style: KeyboardPreferences.writingStyle.rawValue
        )
        record.startedInContainingApp = true
        try? record.transition(to: .launchingApp)
        _ = try? SharedStore.shared.save(record)
        VocaPhoneDarwinCenter.post(.sessionChanged)
        return .result()
    }
}

/// Makes the intent discoverable without the user hunting for it in Shortcuts.
struct VocaPhoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation in \(.applicationName)",
                "Dictate with \(.applicationName)",
            ],
            shortTitle: "Start dictation",
            systemImageName: "mic.fill"
        )
    }
}
