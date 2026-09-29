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
    /// Resting before speech-to-text can run: the setup checklist is the whole
    /// story, and a disabled "Microphone test" beside it was a button that
    /// could not be pressed and did not say why.
    var isHidden = false
    /// A field to dictate into right here, the real thing rather than a test.
    var showsTryField = false
    /// The keyboard is dictating into that field and has not inserted yet.
    /// Dismissing it now drops the document proxy and loses the transcript,
    /// so Done, Clear, Settings and scroll-to-dismiss all stand down.
    var locksTryField = false
    /// A plain, non-destructive link under the card.
    var quietAction: Action?

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
        /// A keyboard dictation targeting Home's own text field. Keep that
        /// field mounted while the session changes state so iOS can retain its
        /// first responder and the keyboard can insert the finished text.
        var isTryFieldSession = false
        /// The try field has the keyboard. The instructions then describe the
        /// keyboard in front of the user rather than how to raise it.
        var isTryFieldFocused = false
        /// Whether all required setup steps are complete. Idle uses this; a
        /// finished transcript does not depend on today's setup state.
        var isReadyToDictate = true
        /// Debug: pin the session card on Transcript ready instead of Ready.
        var showTranscriptOnSession = false
    }

    static func make(_ context: Context, now: Date = Date()) -> HomeSessionCard {
        var card = derive(context, now: now)
        card.locksTryField = card.showsTryField && context.isTryFieldSession
            && awaitsInsertion(context.state)
        return card
    }

    /// Every state from tapping Dictate until the text is in the field. A
    /// field change is not one of them: insertion is parked there until the
    /// user goes back to the field or chooses Insert here.
    private static func awaitsInsertion(_ state: SessionState) -> Bool {
        switch state {
        case .launchingApp, .awaitingReturn, .recording, .finalizing,
             .uploading, .transcribing, .readyToInsert, .inserting, .inserted:
            true
        default:
            false
        }
    }

    private static func derive(_ context: Context, now: Date) -> HomeSessionCard {
        switch context.state {
        case .launchingApp, .awaitingReturn:
            return starting(context)
        case .recording:
            return recording(context)
        case .finalizing, .uploading, .transcribing:
            return processing(context)
        case .readyToInsert, .targetContextChanged, .inserting, .inserted:
            // In-app test has nowhere to insert. Parked on readyToInsert it
            // used to replace Ready to dictate forever. The words live on
            // Latest transcript; this card is how you start again.
            if context.startedInApp {
                return context.showTranscriptOnSession
                    ? finished(context)
                    : resting(context, now: now)
            }
            return delivering(context)
        case .completed:
            return context.showTranscriptOnSession
                ? finished(context)
                : resting(context, now: now)
        case .serverUnavailable, .uploadFailedRecoverable, .transcriptionFailedRecoverable:
            return recoverable(context)
        case .permissionDenied, .transcriptionFailedPermanent:
            return failed(context)
        default:
            if context.showTranscriptOnSession,
               context.startedInApp,
               let transcript = context.transcript,
               !transcript.isEmpty
            {
                return finished(context)
            }
            return resting(context, now: now)
        }
    }

    // MARK: - States

    private static func resting(_ context: Context, now: Date) -> HomeSessionCard {
        // Unready setup stands down for the checklist. Keep the field only
        // while this try-field session still needs it for insertion.
        let isFinishingInsertion: Bool
        switch context.state {
        case .readyToInsert, .targetContextChanged, .inserting, .inserted:
            isFinishingInsertion = true
        default:
            isFinishingInsertion = false
        }
        let keepFieldForActiveInsertion = context.isTryFieldSession && isFinishingInsertion
        guard context.isReadyToDictate || keepFieldForActiveInsertion else {
            return HomeSessionCard(
                status: .inactive,
                title: "Microphone test",
                detail: nil,
                primary: nil,
                isHidden: true
            )
        }
        // Parked on a field change still needs the field; insertion waits
        // for the original field or Insert here.
        let isParkedForFieldChange = context.state == .targetContextChanged
        let detail: String
        let title: String
        let status: VocaStatus
        if context.isReadyToDictate {
            status = .ready
            title = "Try it here"
            if context.isQuickDictationReady, let expiresAt = context.quickDictationExpiresAt {
                // Standby, not recording — and the wording has to make that
                // unmistakable, because the iOS microphone indicator is lit either
                // way. See `QuickDictationAvailability`.
                let duration = context.quickDictationDuration ?? .tenMinutes
                detail = "Quick Dictation is on standby "
                    + duration.standbyDescription(expiringAt: expiresAt)
                    + ". Nothing is being recorded."
            } else if context.isTryFieldFocused {
                detail = "Tap Dictate on the vocaphone keyboard. If another keyboard is up, switch with the globe key."
            } else {
                detail = "Tap the field, switch to the vocaphone keyboard with the globe key, then tap Dictate."
            }
        } else if isParkedForFieldChange {
            status = .working
            title = "Waiting to insert"
            detail = "Return to the keyboard. Go back to the original field, or choose Insert here."
        } else if isFinishingInsertion {
            status = .working
            title = "Finishing dictation"
            detail = "Keep the keyboard open while this dictation finishes."
        } else {
            status = .inactive
            title = "Dictation unavailable"
            detail = "Fix the setup issue above before starting another dictation."
        }
        return HomeSessionCard(
            status: status,
            title: title,
            detail: detail,
            primary: nil,
            secondary: nil,
            showsTryField: true,
            // A microphone test takes the card over and drops the keyboard, so
            // it waits until the field is let go.
            quietAction: context.isReadyToDictate && !context.isTryFieldFocused
                ? Action(title: "Test the microphone only", action: .startTest)
                : nil
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
            secondary: Action(title: "Cancel", action: .cancel),
            showsTryField: context.isTryFieldSession
        )
    }

    private static func recording(_ context: Context) -> HomeSessionCard {
        HomeSessionCard(
            status: .recording,
            title: "Listening",
            detail: context.isTryFieldSession
                ? "Tap Finish here or on the keyboard. The text goes into the field."
                : context.startedInApp
                ? "Tap Finish when you are done."
                : "Recording continues while you return to the app you were typing in.",
            primary: Action(title: "Finish recording", action: .finish, symbol: "stop.fill"),
            secondary: Action(title: "Cancel", action: .cancel),
            showsMeter: true,
            showsTryField: context.isTryFieldSession
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
            secondary: Action(title: "Cancel", action: .cancel),
            showsTryField: context.isTryFieldSession
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
            secondary: Action(title: "Discard recording", action: .cancel),
            showsTryField: context.isTryFieldSession
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
            secondary: nil,
            showsTryField: context.isTryFieldSession
        )
    }
}

/// Home's setup card before dictation can work: every required step as a row,
/// done or with its own button.
///
/// It replaces a card that said "vocaphone needs 3 more steps" and then named
/// and offered a button for only the first of them. The title's count comes
/// from the rows, so the two can never disagree.
struct HomeSetupChecklist: Equatable {
    enum ActionKind: Equatable {
        /// Voice model settings: download a model or pair the gateway.
        case voiceModel
        /// The system prompt, which iOS shows only while access is undecided.
        case allowMicrophone
        /// iOS Settings, for what vocaphone cannot switch on itself.
        case openSystemSettings
    }

    struct Action: Equatable {
        let title: String
        let kind: ActionKind
    }

    struct Row: Equatable, Identifiable {
        let step: SetupStep
        let title: String
        /// What to do, or what is happening. `nil` once the step is done.
        let detail: String?
        let isDone: Bool
        /// `nil` when done, or when something is already on its way.
        let action: Action?

        var id: SetupStep { step }
    }

    let title: String
    let detail: String
    let rows: [Row]

    /// `nil` once dictation can work. Also `nil` when the only thing missing
    /// is a model that is already downloading: the download card says that,
    /// and a checklist over it read as if setup had been thrown away.
    static func make(_ status: SetupStatus, isModelArriving: Bool) -> HomeSetupChecklist? {
        let missing = status.blockingSteps
        guard !missing.isEmpty else { return nil }
        if missing == [.source], isModelArriving { return nil }

        let rows = SetupStep.allCases.filter(\.isRequiredForDictation).map { step in
            row(step, status: status, isModelArriving: isModelArriving)
        }
        let left = rows.filter { !$0.isDone }.count
        return HomeSetupChecklist(
            title: "Finish setting up",
            detail: left == 1 ? "One step left before you can dictate." : "\(left) steps left before you can dictate.",
            rows: rows
        )
    }

    private static func row(
        _ step: SetupStep,
        status: SetupStatus,
        isModelArriving: Bool
    ) -> Row {
        let done = status.isSatisfied(step)
        switch step {
        case .source:
            let onDevice = status.source.selected == .onDevice
            let title = onDevice ? "Voice model" : "Gateway"
            guard !done else { return Row(step: step, title: title, detail: nil, isDone: true, action: nil) }
            if onDevice, isModelArriving {
                return Row(step: step, title: title, detail: "Downloading…", isDone: false, action: nil)
            }
            return Row(
                step: step,
                title: title,
                detail: onDevice ? "Download one to dictate offline." : status.source.readinessDetail,
                isDone: false,
                action: Action(
                    title: onDevice ? "Download" : status.source.recoveryActionTitle,
                    kind: .voiceModel
                )
            )
        case .microphone:
            let title = "Microphone"
            switch status.microphone {
            case .granted:
                return Row(step: step, title: title, detail: nil, isDone: true, action: nil)
            case .undetermined:
                return Row(
                    step: step,
                    title: title,
                    detail: "Recording happens in this app.",
                    isDone: false,
                    action: Action(title: "Allow", kind: .allowMicrophone)
                )
            case .denied:
                return Row(
                    step: step,
                    title: title,
                    detail: "Turned off in iOS Settings.",
                    isDone: false,
                    action: Action(title: "Open Settings", kind: .openSystemSettings)
                )
            }
        case .keyboard:
            let title = "Keyboard"
            let detail: String
            switch status.keyboard {
            case .ready:
                return Row(step: step, title: title, detail: nil, isDone: true, action: nil)
            case .notAdded:
                detail = "Add vocaphone under Keyboards in iOS Settings."
            case .addedButNeverRun, .seenWithoutFullAccess:
                detail = "Turn on Allow Full Access."
            case .silent:
                detail = "Switch to it once to confirm it's still there."
            }
            return Row(
                step: step,
                title: title,
                detail: detail,
                isDone: false,
                action: Action(title: "Open Settings", kind: .openSystemSettings)
            )
        case .firstDictation:
            return Row(step: step, title: step.label, detail: nil, isDone: done, action: nil)
        }
    }
}

/// The one line of stats Home shows, or `nil` before there are any.
enum HomeStatsLine {
    static func make(_ stats: UsageStats, now: Date) -> String? {
        guard stats.hasAny else { return nil }
        let week = stats.lastSevenDays(endingAt: now).reduce(0) { $0 + $1.words }
        let streak = stats.currentStreak(at: now)
        let words = week > 0
            ? "\(StatsFormat.words(week)) this week"
            : "\(StatsFormat.words(stats.totalWords)) so far"
        return streak > 0 ? "\(words) · \(StatsFormat.streak(streak)) streak" : words
    }
}
