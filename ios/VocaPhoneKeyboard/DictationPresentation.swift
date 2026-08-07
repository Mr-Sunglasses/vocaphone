import UIKit

/// What a dictation-bar button does when it is tapped.
///
/// The bar renders from a model that names its own actions, so the mapping from
/// session state to interface lives in exactly one place. Deriving the action a
/// second time inside the tap handler is what let the prominent button in the
/// recoverable-failure states quietly discard the preserved recording.
enum DictationAction: Equatable {
    case start
    case finish
    case insert
    case insertHere
    case openApp
    case retry
    case cancel
    case undo
}

/// A button as the bar should currently present it. Secondary buttons render as
/// icons only, so `title` doubles as their accessibility label.
struct DictationButton: Equatable {
    let title: String
    let symbol: String
    let action: DictationAction
    var isEnabled = true
    var hint: String?

    static let cancel = DictationButton(
        title: "Cancel dictation",
        symbol: "xmark",
        action: .cancel,
        hint: "Discards this dictation."
    )

    static let undo = DictationButton(
        title: "Undo insert",
        symbol: "arrow.uturn.backward",
        action: .undo,
        hint: "Removes the transcript that was just inserted."
    )
}

/// Colour families the bar cycles through. Kept symbolic so the palette decides
/// the actual values per appearance, the way the key colours already do.
enum DictationAccent: Equatable {
    case brand
    case handoff
    case listening
    case working
    case ready
    case alert
    case locked
}

/// Motion applied to the status indicator, which is the bar's cheapest signal
/// that something is still happening while the user waits.
enum DictationPulse: Equatable {
    case steady
    case listening
    case working
}

enum WaveformMode: Equatable {
    /// Driven by the microphone levels the app publishes.
    case live
    /// A travelling pulse, used while work is happening off-device and there is
    /// no level to show. It must not be mistaken for audio.
    case indeterminate
}

/// The single slot beneath the headline. Only one of these is meaningful at a
/// time, which is what let the old card's stacked subtitle, meter and toolbar
/// collapse into one bar.
enum DictationBody: Equatable {
    /// Language and writing-style pickers, shown only when no session owns the
    /// bar — which is exactly when changing them still affects the next
    /// dictation.
    case controls
    case waveform(WaveformMode)
    case message(String)
}

/// Everything the bar needs to draw itself for one moment in a session.
struct DictationBarModel: Equatable {
    var title: String
    var body: DictationBody
    var accent: DictationAccent
    var pulse: DictationPulse
    var primary: DictationButton
    var secondaries: [DictationButton]
    var showsElapsedTime: Bool
    /// A live session earns the taller bar; an idle one gives the height back
    /// to the keys.
    var isExpanded: Bool
}

/// The inputs the model is derived from. A struct rather than a long parameter
/// list so a test can vary one fact at a time.
struct DictationContext: Equatable {
    var state: SessionState = .idle
    var hasFullAccess = true
    var transcript: String?
    var errorMessage: String?
    var autoInsertsTranscripts = false
    var canRetry = false
    var canUndo = false
}

extension DictationBarModel {
    static func make(_ context: DictationContext) -> DictationBarModel {
        guard context.hasFullAccess else { return locked }
        switch context.state {
        case .idle, .completed, .canceled, .expired:
            return resting(context)
        case .launchingApp, .awaitingReturn:
            return handoff
        case .recording:
            return listening
        case .finalizing, .uploading, .transcribing:
            return working(context.state)
        case .readyToInsert:
            return ready(context)
        case .targetContextChanged:
            return waitingForField(context)
        case .inserting, .inserted:
            return inserting
        case .serverUnavailable, .uploadFailedRecoverable, .transcriptionFailedRecoverable:
            return recoverableFailure(context)
        case .permissionDenied:
            return permissionDenied
        case .transcriptionFailedPermanent:
            return permanentFailure(context)
        }
    }

    private static let locked = DictationBarModel(
        title: "Full Access needed",
        body: .message("Turn it on in Settings › General › Keyboard › vocaphone."),
        accent: .locked,
        pulse: .steady,
        primary: DictationButton(
            title: "Locked",
            symbol: "lock.fill",
            action: .start,
            isEnabled: false
        ),
        secondaries: [],
        showsElapsedTime: false,
        isExpanded: true
    )

    private static func resting(_ context: DictationContext) -> DictationBarModel {
        DictationBarModel(
            title: context.state == .completed ? "Text inserted" : "Ready to dictate",
            body: .controls,
            accent: context.state == .completed ? .ready : .brand,
            pulse: .steady,
            primary: DictationButton(
                title: "Dictate",
                symbol: "mic.fill",
                action: .start,
                hint: "Opens vocaphone and starts private dictation."
            ),
            secondaries: context.canUndo ? [.undo] : [],
            showsElapsedTime: false,
            isExpanded: false
        )
    }

    private static let handoff = DictationBarModel(
        title: "Opening vocaphone",
        body: .message("Start speaking as soon as the app appears."),
        accent: .handoff,
        pulse: .working,
        primary: DictationButton(
            title: "Open app",
            symbol: "arrow.up.forward.app.fill",
            action: .openApp,
            hint: "Opens vocaphone to continue."
        ),
        secondaries: [.cancel],
        showsElapsedTime: false,
        isExpanded: true
    )

    private static let listening = DictationBarModel(
        title: "Listening",
        body: .waveform(.live),
        accent: .listening,
        pulse: .listening,
        primary: DictationButton(
            title: "Finish",
            symbol: "stop.fill",
            action: .finish,
            hint: "Stops recording and starts transcription."
        ),
        secondaries: [.cancel],
        showsElapsedTime: true,
        isExpanded: true
    )

    private static func working(_ state: SessionState) -> DictationBarModel {
        DictationBarModel(
            title: state == .transcribing ? "Transcribing on your Mac" : "Sending to your Mac",
            body: .waveform(.indeterminate),
            accent: .working,
            pulse: .working,
            primary: DictationButton(
                title: "Working",
                symbol: "waveform",
                action: .finish,
                isEnabled: false
            ),
            secondaries: [.cancel],
            showsElapsedTime: false,
            isExpanded: true
        )
    }

    private static func ready(_ context: DictationContext) -> DictationBarModel {
        let fallback = context.autoInsertsTranscripts
            ? "Inserting automatically…"
            : "Tap Insert to place the text."
        return DictationBarModel(
            title: "Transcript ready",
            body: .message(quoted(context.transcript) ?? fallback),
            accent: .ready,
            pulse: .steady,
            primary: DictationButton(
                title: "Insert",
                symbol: "text.badge.plus",
                action: .insert,
                hint: "Inserts the transcript at the cursor."
            ),
            secondaries: [.cancel],
            showsElapsedTime: false,
            isExpanded: true
        )
    }

    private static func waitingForField(_ context: DictationContext) -> DictationBarModel {
        DictationBarModel(
            title: "Waiting for its own field",
            body: .message(
                quoted(context.transcript) ?? "Return to that field, or insert it here."
            ),
            accent: .working,
            pulse: .steady,
            primary: DictationButton(
                title: "Insert here",
                symbol: "text.badge.plus",
                action: .insertHere,
                hint: "Inserts the waiting transcript into this field instead."
            ),
            secondaries: [.cancel],
            showsElapsedTime: false,
            isExpanded: true
        )
    }

    private static let inserting = DictationBarModel(
        title: "Inserting",
        body: .message("Placing the transcript at the cursor."),
        accent: .ready,
        pulse: .working,
        primary: DictationButton(
            title: "Inserting",
            symbol: "text.badge.checkmark",
            action: .insert,
            isEnabled: false
        ),
        secondaries: [],
        showsElapsedTime: false,
        isExpanded: true
    )

    /// The recording survived, so retrying it is the prominent action. It used
    /// to be a small icon beside a prominent "New", which threw the preserved
    /// audio away on the very tap most people reached for.
    private static func recoverableFailure(_ context: DictationContext) -> DictationBarModel {
        let primary = context.canRetry
            ? DictationButton(
                title: "Retry",
                symbol: "arrow.clockwise",
                action: .retry,
                hint: "Sends the preserved recording again."
            )
            : DictationButton(title: "Dictate", symbol: "mic.fill", action: .start)
        return DictationBarModel(
            title: context.state == .serverUnavailable
                ? "Gateway unavailable"
                : "Transcription paused",
            body: .message(context.errorMessage ?? "Your recording is preserved."),
            accent: .alert,
            pulse: .steady,
            primary: primary,
            // Cancelling returns the bar to Ready with Dictate already in place,
            // so a separate "new recording" button only crowded the title out.
            secondaries: [.cancel],
            showsElapsedTime: false,
            isExpanded: true
        )
    }

    private static let permissionDenied = DictationBarModel(
        title: "Microphone access needed",
        body: .message("Allow the microphone in vocaphone, then dictate again."),
        accent: .alert,
        pulse: .steady,
        primary: DictationButton(
            title: "Open app",
            symbol: "gear",
            action: .start,
            hint: "Opens vocaphone so the microphone prompt can be answered."
        ),
        secondaries: [],
        showsElapsedTime: false,
        isExpanded: true
    )

    private static func permanentFailure(_ context: DictationContext) -> DictationBarModel {
        DictationBarModel(
            title: "Transcription failed",
            body: .message(context.errorMessage ?? "Please make a new recording."),
            accent: .alert,
            pulse: .steady,
            primary: DictationButton(
                title: "Try again",
                symbol: "arrow.clockwise",
                action: .start,
                hint: "Starts a new recording."
            ),
            secondaries: [],
            showsElapsedTime: false,
            isExpanded: true
        )
    }

    /// A one-line rendering of the transcript, so the user can see what they are
    /// about to insert instead of trusting an unlabelled button.
    static func quoted(_ transcript: String?, limit: Int = 96) -> String? {
        guard let transcript else { return nil }
        let collapsed = transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return "“\(collapsed)”" }
        let clipped = collapsed.prefix(limit).trimmingCharacters(in: .whitespaces)
        return "“\(clipped)…”"
    }

    static func elapsedText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
