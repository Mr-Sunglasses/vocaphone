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

/// The semantic colour a state is drawn in.
///
/// One role per meaning, and no more: an earlier version had a separate purple
/// for the hand-off, which said only that vocaphone owns a fourth colour.
/// Opening the app is an ordinary, expected step, so it is brand — the same
/// colour as every other "this is fine".
enum DictationAccent: Equatable {
    /// Resting, and any state the product considers fine.
    case brand
    /// Live capture, and nothing else.
    case recording
    /// Waiting on work: finalizing, uploading, transcribing, or a transcript
    /// stranded by a change of field.
    case working
    /// A finished, useful result.
    case ready
    /// A failure the user has to answer.
    case error
    /// Unavailable because a prerequisite is missing. Neutral: a locked keyboard
    /// is not a broken one.
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
    /// Typing candidates. Only ever in the idle bar: while a transcript is
    /// arriving, competing for that row would be noise.
    case candidates([TypingCandidate])
    case waveform(WaveformMode)
    case message(String)
}

/// How the bar arranges itself.
///
/// Two shapes, not two containers. The keyboard settled on one morphing
/// container for every dictation state, and the typing strip extends that
/// principle rather than breaking it: idle is a single row, and anything with a
/// session to report keeps the headline-and-body pair.
enum DictationBarLayout: Equatable {
    /// One row: candidates or pickers, and a compact circular Dictate button.
    /// The shape the keyboard spends nearly all its life in.
    case strip
    /// Headline, body and a labelled action — every state that has something
    /// to say about a session.
    case status
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
    /// What VoiceOver should say when the bar arrives at this state, or `nil`
    /// for states that are not worth interrupting for. Polling re-renders the
    /// same state several times a second; only a genuine transition announces.
    var announcement: String?
    var layout: DictationBarLayout = .status
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
    /// Typing candidates for the idle bar. Empty in every state that owns a
    /// session, because the strip is not shown there.
    var candidates: [TypingCandidate] = []
    /// The keyboard found a fresh Quick Dictation heartbeat when it created this
    /// session. This is presentation state only; the containing app confirms its
    /// active audio input before recording starts.
    var prefersQuickDictation = false
    /// Where this session's transcription runs, when the containing app has
    /// resolved it. `nil` for a legacy or interrupted record, and the copy stays
    /// neutral rather than guessing — naming the wrong place is worse than
    /// naming none.
    var processingLocation: SessionProcessingLocation?
}

extension DictationBarModel {
    static func make(_ context: DictationContext) -> DictationBarModel {
        guard context.hasFullAccess else { return locked }
        switch context.state {
        case .idle, .completed, .canceled, .expired:
            return resting(context)
        case .launchingApp, .awaitingReturn:
            return handoff(context)
        case .recording:
            return listening
        case .finalizing, .uploading, .transcribing:
            return working(context)
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

    /// The keyboard's phrasing of the Full Access instruction. Front-loaded so
    /// that the switch to turn on survives the bar's two lines; the containing
    /// app gives the full path.
    static let fullAccessPath = AppConfiguration.fullAccessKeyboardHint

    private static let locked = DictationBarModel(
        title: "Full Access needed",
        body: .message(fullAccessPath),
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
        isExpanded: true,
        announcement: nil
    )

    private static func resting(_ context: DictationContext) -> DictationBarModel {
        // A finished insertion keeps the headline and the Undo button: "Text
        // inserted" with an undo still available is not the moment to start
        // offering candidates for the next word.
        let justInserted = context.state == .completed
        let showsCandidates = !justInserted && !context.candidates.isEmpty
        return DictationBarModel(
            title: justInserted ? "Text inserted" : "Ready to dictate",
            body: showsCandidates ? .candidates(context.candidates) : .controls,
            accent: justInserted ? .ready : .brand,
            pulse: .steady,
            primary: DictationButton(
                title: "Dictate",
                symbol: "mic.fill",
                action: .start,
                hint: "Opens vocaphone and starts private dictation."
            ),
            secondaries: context.canUndo ? [.undo] : [],
            showsElapsedTime: false,
            isExpanded: false,
            announcement: justInserted ? "Text inserted" : nil,
            layout: justInserted ? .status : .strip
        )
    }

    private static func handoff(_ context: DictationContext) -> DictationBarModel {
        if context.state == .launchingApp, context.prefersQuickDictation {
            return DictationBarModel(
                title: "Starting dictation",
                body: .message("Quick Dictation keeps you in this app."),
                accent: .brand,
                pulse: .working,
                primary: DictationButton(
                    title: "Open app",
                    symbol: "arrow.up.forward.app.fill",
                    action: .openApp,
                    hint: "Opens vocaphone if starting here does not complete."
                ),
                secondaries: [.cancel],
                showsElapsedTime: false,
                isExpanded: true,
                announcement: nil
            )
        }

        return DictationBarModel(
            title: "Opening vocaphone",
            body: .message("Speak when the app appears."),
            accent: .brand,
            pulse: .working,
            primary: DictationButton(
                title: "Open app",
                symbol: "arrow.up.forward.app.fill",
                action: .openApp,
                hint: "Opens vocaphone to continue."
            ),
            secondaries: [.cancel],
            showsElapsedTime: false,
            isExpanded: true,
            announcement: nil
        )
    }

    private static let listening = DictationBarModel(
        title: "Listening",
        body: .waveform(.live),
        accent: .recording,
        pulse: .listening,
        primary: DictationButton(
            title: "Finish",
            symbol: "stop.fill",
            action: .finish,
            hint: "Stops recording and starts transcription."
        ),
        secondaries: [.cancel],
        showsElapsedTime: true,
        isExpanded: true,
        announcement: "Recording started"
    )

    /// Where the work is happening, said plainly.
    ///
    /// Never "your Mac": a gateway may be a Linux box, a home server or a VPS,
    /// and the interface has no business guessing which. Never "local" for a
    /// gateway either — audio genuinely leaves the phone on that route.
    private static func working(_ context: DictationContext) -> DictationBarModel {
        let title: String = switch context.state {
        case .finalizing:
            "Finishing recording"
        case .uploading:
            switch context.processingLocation {
            case .gateway: "Sending to your gateway"
            case .onDevice: "Preparing on this iPhone"
            case nil: "Preparing transcript"
            }
        default:
            switch context.processingLocation {
            case .gateway: "Transcribing on your gateway"
            case .onDevice: "Transcribing on this iPhone"
            case nil: "Transcribing"
            }
        }
        return DictationBarModel(
            title: title,
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
            isExpanded: true,
            announcement: context.state == .finalizing ? title : nil
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
            isExpanded: true,
            announcement: "Transcript ready"
        )
    }

    private static func waitingForField(_ context: DictationContext) -> DictationBarModel {
        let detail = quoted(context.transcript).map {
            $0 + " This is a different text field from the one where you started."
        } ?? "Go back to the field you dictated for, or insert the text in this field."
        return DictationBarModel(
            title: "Your text is ready",
            body: .message(detail),
            accent: .working,
            pulse: .steady,
            primary: DictationButton(
                title: "Insert in this field",
                symbol: "text.badge.plus",
                action: .insertHere,
                hint: "Inserts the waiting transcript at the cursor in this field."
            ),
            secondaries: [.cancel],
            showsElapsedTime: false,
            isExpanded: true,
            announcement: "Text ready in a different field. Return to the original field or insert in this field."
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
        isExpanded: true,
        announcement: nil
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
        let title = context.state == .serverUnavailable
            ? "Gateway unavailable"
            : "Transcription paused"
        return DictationBarModel(
            title: title,
            body: .message(context.errorMessage ?? "Your recording is preserved."),
            accent: .error,
            pulse: .steady,
            primary: primary,
            // Cancelling returns the bar to Ready with Dictate already in place,
            // so a separate "new recording" button only crowded the title out.
            secondaries: [.cancel],
            showsElapsedTime: false,
            isExpanded: true,
            announcement: context.canRetry ? "\(title). Retry is available." : title
        )
    }

    private static let permissionDenied = DictationBarModel(
        title: "Microphone access needed",
        body: .message("Open vocaphone to allow the microphone, then dictate again."),
        accent: .error,
        pulse: .steady,
        primary: DictationButton(
            title: "Open app",
            symbol: "arrow.up.forward.app.fill",
            action: .start,
            hint: "Opens vocaphone so the microphone prompt can be answered."
        ),
        secondaries: [],
        showsElapsedTime: false,
        isExpanded: true,
        announcement: "Microphone access needed"
    )

    private static func permanentFailure(_ context: DictationContext) -> DictationBarModel {
        DictationBarModel(
            title: "Transcription failed",
            body: .message(context.errorMessage ?? "Please make a new recording."),
            accent: .error,
            pulse: .steady,
            primary: DictationButton(
                title: "Try again",
                symbol: "arrow.clockwise",
                action: .start,
                hint: "Starts a new recording."
            ),
            secondaries: [],
            showsElapsedTime: false,
            isExpanded: true,
            announcement: "Transcription failed"
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
