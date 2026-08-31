import SwiftUI

/// What tapping the session card's buttons does.
enum HomeSessionAction: Equatable {
    case startTest
    case finish
    case cancel
    case retry
    case copyTranscript
}

/// The home screen's one session card, derived rather than assembled in the
/// view.
///
/// There used to be a row for the state, a row for Quick Dictation, a row for
/// the message and two rows of buttons, each of which could say "Ready" about
/// something different. One card, one status, one primary action — and the model
/// that decides them is pure, so every combination can be checked without an
/// audio stack.
struct HomeSessionCard: Equatable {
    struct Action: Equatable {
        let title: String
        let action: HomeSessionAction
        var symbol: String?
    }

    var status: VocaStatus
    var title: String
    var detail: String?
    var primary: Action?
    /// Rendered as a plain or destructive button beside the primary.
    var secondary: Action?
    var showsMeter = false
    /// The finished transcript belongs on this card only while the app itself
    /// owns the result; a keyboard dictation delivers it into the host field.
    var showsTranscript = false

    /// Everything the card is derived from.
    struct Context: Equatable {
        var state: SessionState = .idle
        var isRecording = false
        var isQuickDictationReady = false
        var quickDictationExpiresAt: Date?
        var quickDictationDuration: QuickDictationDuration?
        var processingLocation: SessionProcessingLocation?
        var transcript: String?
        var errorMessage: String?
        var canRetry = false
        var startedInApp = true
        var isSourceReady = true
    }

    static func make(_ context: Context, now: Date = Date()) -> HomeSessionCard {
        switch context.state {
        case .launchingApp, .awaitingReturn:
            return starting(context)
        case .recording:
            return recording(context)
        case .finalizing, .uploading, .transcribing:
            return processing(context)
        case .readyToInsert, .targetContextChanged, .inserting, .inserted:
            return delivering(context)
        case .completed:
            return finished(context)
        case .serverUnavailable, .uploadFailedRecoverable, .transcriptionFailedRecoverable:
            return recoverable(context)
        case .permissionDenied, .transcriptionFailedPermanent:
            return failed(context)
        default:
            return resting(context, now: now)
        }
    }

    // MARK: - States

    private static func resting(_ context: Context, now: Date) -> HomeSessionCard {
        let detail: String?
        if context.isQuickDictationReady, let expiresAt = context.quickDictationExpiresAt {
            // Standby, not recording — and the wording has to make that
            // unmistakable, because the iOS microphone indicator is lit either
            // way. See `QuickDictationAvailability`.
            let duration = context.quickDictationDuration ?? .tenMinutes
            detail = "Quick Dictation is on standby "
                + duration.standbyDescription(expiringAt: expiresAt)
                + ". Nothing is being recorded."
        } else if !context.isSourceReady {
            detail = "Choose where speech becomes text before dictating."
        } else {
            detail = "Dictate from any app with the vocaphone keyboard. The first tap "
                + "opens vocaphone to record; swipe back once it starts."
        }
        return HomeSessionCard(
            // Lead with what the product can do, not with what it is not doing.
            // "Ready to dictate" is the honest claim whenever the selected
            // source works — Quick Dictation only decides whether the first tap
            // has to leave the host app, which the detail line explains.
            status: context.isSourceReady ? .ready : .inactive,
            title: context.isSourceReady ? "Ready to dictate" : "Not ready to dictate",
            detail: detail,
            primary: Action(
                title: "Start microphone test",
                action: .startTest,
                symbol: "mic.fill"
            ),
            secondary: nil
        )
    }

    /// The keyboard has asked for a recording and the microphone is warming.
    /// Brief, but it must not read as "nothing recording" — the user has already
    /// tapped Dictate and may be about to start speaking.
    private static func starting(_ context: Context) -> HomeSessionCard {
        HomeSessionCard(
            status: .working,
            title: "Starting the microphone",
            detail: "The keyboard asked vocaphone to record. Speak once it says Listening.",
            primary: nil,
            secondary: Action(title: "Cancel", action: .cancel)
        )
    }

    private static func recording(_ context: Context) -> HomeSessionCard {
        HomeSessionCard(
            status: .recording,
            title: "Listening",
            detail: context.startedInApp
                ? "Tap Finish when you are done."
                : "Recording continues while you return to the app you were typing in.",
            primary: Action(title: "Finish recording", action: .finish, symbol: "stop.fill"),
            secondary: Action(title: "Cancel", action: .cancel),
            showsMeter: true
        )
    }

    private static func processing(_ context: Context) -> HomeSessionCard {
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
        return HomeSessionCard(
            status: .working,
            title: title,
            detail: context.processingLocation == .onDevice
                ? "The speech-to-text model is running on this iPhone. No audio leaves it."
                : context.processingLocation == .gateway
                    ? "Your gateway is running its speech-to-text model on this recording."
                    : nil,
            primary: nil,
            secondary: Action(title: "Cancel", action: .cancel)
        )
    }

    private static func delivering(_ context: Context) -> HomeSessionCard {
        HomeSessionCard(
            status: .ready,
            title: "Transcript ready",
            detail: context.startedInApp
                ? nil
                : "Return to the keyboard to insert it into the field you were typing in.",
            primary: context.startedInApp && context.transcript != nil
                ? Action(title: "Copy transcript", action: .copyTranscript, symbol: "doc.on.doc")
                : nil,
            secondary: nil,
            showsTranscript: context.startedInApp
        )
    }

    private static func finished(_ context: Context) -> HomeSessionCard {
        HomeSessionCard(
            status: .ready,
            title: context.startedInApp ? "Transcript ready" : "Text inserted",
            detail: context.startedInApp
                ? nil
                : "The transcript went into the field you were typing in.",
            primary: context.transcript != nil
                ? Action(title: "Copy transcript", action: .copyTranscript, symbol: "doc.on.doc")
                : Action(title: "Start microphone test", action: .startTest, symbol: "mic.fill"),
            secondary: nil,
            showsTranscript: context.transcript != nil
        )
    }

    /// The audio survived, so Retry is the prominent action and Cancel is the
    /// quiet one. Getting this the other way round throws away work the user
    /// already spoke.
    private static func recoverable(_ context: Context) -> HomeSessionCard {
        HomeSessionCard(
            status: .attention,
            title: context.state == .serverUnavailable
                ? "Gateway unavailable"
                : "Transcription paused",
            detail: context.errorMessage ?? "Your recording is preserved.",
            primary: context.canRetry
                ? Action(title: "Retry", action: .retry, symbol: "arrow.clockwise")
                : Action(title: "Start microphone test", action: .startTest, symbol: "mic.fill"),
            secondary: Action(title: "Discard recording", action: .cancel)
        )
    }

    private static func failed(_ context: Context) -> HomeSessionCard {
        HomeSessionCard(
            status: .failed,
            title: context.state == .permissionDenied
                ? "Microphone access needed"
                : "Transcription failed",
            detail: context.errorMessage
                ?? "Make a new recording once the problem is fixed.",
            primary: Action(
                title: "Start microphone test",
                action: .startTest,
                symbol: "mic.fill"
            ),
            secondary: nil
        )
    }
}
