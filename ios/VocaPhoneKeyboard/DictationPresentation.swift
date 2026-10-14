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
    case openFullAccessSettings
    case retry
    case cancel
    case undo
    /// Puts away a message that has nothing left to do: a failure that ended
    /// the session, or a notice about one. Nothing is discarded by it.
    case dismiss
    /// Opens vocaphone on Home, where the missing voice model is one tap away.
    /// Not `.start`: a dictation started without a model fails in the app and
    /// comes straight back here, which is the loop this replaces.
    case openVoiceModelSetup
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

    /// The × beside a waiting transcript. It cancels the session, which is
    /// what stops every field offering the text, but the transcript itself
    /// stays in vocaphone's Transcripts like any other — so the button says
    /// dismiss, not discard, and the hint says where the words went.
    static let dismissTranscript = DictationButton(
        title: "Dismiss transcript",
        symbol: "xmark",
        action: .cancel,
        hint: "Hides this transcript here. It stays in Transcripts in vocaphone."
    )

    static let dismiss = DictationButton(
        title: "Dismiss",
        symbol: "xmark",
        action: .dismiss,
        hint: "Hides this message."
    )

    static let openVoiceModelSetup = DictationButton(
        title: "Open vocaphone",
        symbol: "arrow.down.circle.fill",
        action: .openVoiceModelSetup,
        hint: "Opens vocaphone, where you can download a voice model."
    )

    /// A new recording. The microphone, never the circular arrow: that one is
    /// Retry, which resends audio that was kept, and two buttons that look the
    /// same and do opposite things with somebody's recording is how the kept
    /// one gets thrown away.
    static let newRecording = DictationButton(
        title: "Dictate",
        symbol: "mic.fill",
        action: .start,
        hint: "Starts a new recording."
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
    /// The failure's code, which picks the keyboard's own short wording. The
    /// message above is the app's, written for a screen with room to explain.
    var errorCode: String?
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
    /// The keyboard that was inserting this transcript ended before it could
    /// record the result, so the text may already be in the field. Offered
    /// again, never inserted automatically.
    var insertionWasInterrupted = false
    /// Recording ended because it reached the length cap, not because anyone
    /// tapped Finish. Said in the processing title, or the cut-off sentence
    /// reads as a lost one.
    var stoppedAtRecordingLimit = false
    /// Something this keyboard has to say while no session owns the bar.
    var notice: DictationNotice?
}

/// What the keyboard says when there is no session to show, but there is news
/// about one — or a reason the next one cannot start.
///
/// Each is shown once, in the status bar above the keys, with the one action
/// that helps and a way to put it away. They exist because the alternative was
/// silence: a microphone that would not start, or a hand-off vocaphone never
/// answered, ended the session as `canceled` or `expired`, and both of those
/// render as an ordinary idle keyboard.
enum DictationNotice: Equatable {
    /// On-device transcription is selected and the model is not on this
    /// iPhone, so Dictate would only fail inside the app.
    case voiceModelNeeded
    /// The app could not start the microphone and cancelled the session.
    case recordingDidNotStart
    /// The hand-off was never answered: nothing was recorded.
    case handoffTimedOut
    /// A dictation that had recorded something stopped answering.
    case dictationTimedOut
    /// A transcript waited for a tap longer than the keyboard offers one.
    case transcriptExpired

    /// How long after a session ended its notice is still news. A keyboard
    /// opened tomorrow has no business reporting yesterday's failure.
    static let freshness: TimeInterval = 10 * 60

    /// The notice an ended session deserves, or `nil` when it ended the way
    /// somebody asked it to. A plain Cancel has no error and says nothing, and
    /// nor does discarding a failure: that cancel keeps the failure's error,
    /// so only the microphone's own code means the recording never began.
    static func forEndedSession(_ record: SessionRecord, now: Date = Date()) -> DictationNotice? {
        guard record.sourceDocumentID != SessionOrigin.microphoneTest,
              now.timeIntervalSince(record.updatedAt) <= freshness
        else { return nil }
        switch record.state {
        case .canceled:
            return record.error?.code == DictationFailure.recordingStartFailedCode
                ? .recordingDidNotStart
                : nil
        case .expired:
            if let transcript = record.transcript,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return .transcriptExpired
            }
            return record.localAudioReference == nil ? .handoffTimedOut : .dictationTimedOut
        default:
            return nil
        }
    }

    /// What to say about a session this keyboard has just expired, judged on
    /// the record as it was before expiry — the state it was stuck in is the
    /// only thing that says which wait ran out.
    ///
    /// Only for a wait that ran out recently. A hand-off abandoned yesterday
    /// is expired by the first keyboard to come up today, and reporting that
    /// as news would be a failure the user never saw happen.
    static func forExpiry(of record: SessionRecord, now: Date = Date()) -> DictationNotice? {
        guard record.sourceDocumentID != SessionOrigin.microphoneTest,
              let window = SessionExpiryPolicy.window(for: record.state),
              now.timeIntervalSince(record.updatedAt) <= window + freshness
        else { return nil }
        if let transcript = record.transcript,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .transcriptExpired
        }
        switch record.state {
        case .launchingApp, .awaitingReturn: return .handoffTimedOut
        case .inserting: return nil
        default: return .dictationTimedOut
        }
    }

    /// A failure that ended its session and is worth showing to a keyboard
    /// that was not watching when it happened: still recent, and not one of
    /// vocaphone's own microphone tests.
    static func showsEndedFailure(_ record: SessionRecord, now: Date = Date()) -> Bool {
        guard record.sourceDocumentID != SessionOrigin.microphoneTest,
              [.transcriptionFailedPermanent, .permissionDenied].contains(record.state)
        else { return false }
        return now.timeIntervalSince(record.updatedAt) <= freshness
    }
}

extension DictationBarModel {
    /// The surface's one line for this state: the bar's own short body, never
    /// the app's paragraph about it.
    ///
    /// Failures used to come out as "Title. The app's whole error message.
    /// Button." — three sentences over somebody else's text field, written for
    /// a screen with room to explain, which pushed the short line below off the
    /// keyboard entirely. The detail stays in vocaphone, where it can be read.
    func surfaceMessage(for state: SessionState) -> String? {
        switch state {
        case .serverUnavailable, .uploadFailedRecoverable,
             .transcriptionFailedRecoverable, .transcriptionFailedPermanent,
             .permissionDenied:
            if case let .message(message) = body { return message }
        case .readyToInsert, .targetContextChanged:
            if case let .message(message) = body { return message }
        case .finalizing, .uploading, .transcribing:
            return title
        default:
            break
        }
        return Self.surfaceLine(for: state)
    }

    /// The single line the dictation surface shows in the middle, or `nil` when
    /// the state has nothing to explain.
    ///
    /// Deliberately shorter than the card's copy above, and deliberately not a
    /// concatenation of it. The card is two lines inside an app; this is one
    /// line over somebody else's text field, and the fix is already on the
    /// button beside it — "retry after checking the selected model" is an
    /// instruction for a screen the reader is not on.
    ///
    /// What survives the cut is the fact that changes what the person does
    /// next: the recording is still there, so they can retry instead of saying
    /// it all again.
    static func surfaceLine(for state: SessionState) -> String? {
        switch state {
        case .serverUnavailable:
            "Can't reach your gateway. Recording kept."
        case .uploadFailedRecoverable:
            "Upload failed. Recording kept."
        case .transcriptionFailedRecoverable:
            "Couldn't transcribe. Recording kept."
        case .transcriptionFailedPermanent:
            "Couldn't transcribe this recording."
        case .permissionDenied:
            "vocaphone needs microphone access."
        case .targetContextChanged:
            "Tap the field you were typing in."
        default:
            nil
        }
    }

    static func make(_ context: DictationContext) -> DictationBarModel {
        guard context.hasFullAccess else { return locked }
        switch context.state {
        case .idle, .completed, .canceled, .expired:
            if let notice = context.notice { return Self.notice(notice) }
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

    /// The states the dictation surface owns outright: it fills the keyboard,
    /// the keys are put away, and the old bar stays out of it.
    ///
    /// Capture and the wait for its transcript, and nothing after. A
    /// transcript waiting for a tap, a field that changed, and every failure
    /// used to own the whole keyboard too — and a session is adopted by every
    /// keyboard appearance in every app, for up to an hour. Somebody who
    /// dictated, then went to reply to a message in another app, found no keys
    /// there: only an Insert button and a ×, and × threw the transcript away.
    /// Those states now sit in the status bar above the keys, with their
    /// action and a way to put them away, and typing carries on underneath.
    static func surfaceOwnsKeyboard(
        _ state: SessionState,
        hasFullAccess: Bool
    ) -> Bool {
        // Without Full Access the keyboard is locked, and the only thing worth
        // saying is the path to unlock it. That is the old bar's card, and it
        // has to be allowed to appear whatever state the stored session is in.
        guard hasFullAccess else { return false }
        return switch state {
        // The hand-off belongs here as much as the recording does. Measured on
        // device: a tap on the microphone goes to `launchingApp` first, and
        // that state's bar model is the expanded status card — 84 pt against
        // the strip's 54. The keyboard grew by thirty points before recording
        // had even begun, which is the jump, and the flash of a card nobody
        // asked for is the same event seen from the other side.
        case .launchingApp, .awaitingReturn: true
        case .recording, .finalizing, .uploading, .transcribing: true
        default: false
        }
    }

    /// The keyboard's phrasing of the Full Access instruction. Front-loaded so
    /// that the switch to turn on survives the bar's two lines, and naming the
    /// same route the button takes: vocaphone opens its own page in Settings,
    /// where Keyboards holds the switch.
    static let fullAccessPath = AppConfiguration.fullAccessKeyboardHint

    /// Named for what it gets done. "Locked" described the keyboard, not the
    /// button, and a button labelled with a state is one nobody expects to tap.
    private static let locked = DictationBarModel(
        title: "Full Access needed",
        body: .message(fullAccessPath),
        accent: .locked,
        pulse: .steady,
        primary: DictationButton(
            title: "Turn on Full Access",
            symbol: "lock.open.fill",
            action: .openFullAccessSettings,
            hint: "Opens vocaphone, which opens its page in Settings. Tap Keyboards, then Allow Full Access."
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
            symbol: "checkmark",
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
        let title: String = if context.stoppedAtRecordingLimit {
            // Said for the whole wait, not only while finishing: the last
            // sentence was cut off by the cap, and the person needs to know
            // that before the transcript arrives without it.
            recordingLimitTitle
        } else {
            processingTitle(context)
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

    /// "Stopped at the 2-minute limit", from the cap itself so the two cannot
    /// disagree.
    static var recordingLimitTitle: String {
        "Stopped at the \(RecordingClock.limitPhrase) limit"
    }

    /// The Live Activity's line while the app processes a recording. One the
    /// cap stopped keeps saying so for the whole wait, as the bar does: the
    /// steps after finishing used to replace it within a second, so the Lock
    /// Screen never said why the last sentence was missing.
    static func processingActivityStatus(_ status: String, for record: SessionRecord) -> String {
        record.stoppedAtRecordingLimit == true ? recordingLimitTitle : status
    }

    private static func processingTitle(_ context: DictationContext) -> String {
        switch context.state {
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
    }

    private static func ready(_ context: DictationContext) -> DictationBarModel {
        if context.insertionWasInterrupted { return interruptedInsertion(context) }
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
            secondaries: [.dismissTranscript],
            showsElapsedTime: false,
            isExpanded: true,
            announcement: "Transcript ready"
        )
    }

    /// Says what is known and no more: the insertion started, and nothing
    /// recorded whether it finished. The person can see the field; this
    /// keyboard cannot.
    private static func interruptedInsertion(_ context: DictationContext) -> DictationBarModel {
        let detail = "Insertion may have been interrupted. Check the field before inserting again."
        return DictationBarModel(
            title: "Insertion interrupted",
            body: .message(quoted(context.transcript).map { "\($0) \(detail)" } ?? detail),
            accent: .working,
            pulse: .steady,
            primary: DictationButton(
                title: "Insert",
                symbol: "text.badge.plus",
                // A parked transcript only goes in through the explicit
                // "insert here" path, which bypasses the field guard.
                action: context.state == .targetContextChanged ? .insertHere : .insert,
                hint: "Inserts the transcript at the cursor, even if part of it is already there."
            ),
            secondaries: [.dismissTranscript],
            showsElapsedTime: false,
            isExpanded: true,
            announcement: "Insertion may have been interrupted. Check the field, then insert or dismiss."
        )
    }

    private static func waitingForField(_ context: DictationContext) -> DictationBarModel {
        // The interrupted insertion is the more important thing to say: the
        // text may already be in this field or another, and "Insert in this
        // field" alone reads as safe to tap.
        if context.insertionWasInterrupted { return interruptedInsertion(context) }
        let detail = quoted(context.transcript).map {
            $0 + " This is a different text field from the one where you started."
        } ?? "Go back to the field you dictated for, or insert the text in this field."
        return DictationBarModel(
            title: "Your text is ready",
            body: .message(detail),
            accent: .working,
            pulse: .steady,
            // "Insert here": the label the app and Home tell people to look
            // for, and short enough to survive the narrowest bar whole.
            primary: DictationButton(
                title: "Insert here",
                symbol: "text.badge.plus",
                action: .insertHere,
                hint: "Inserts the waiting transcript at the cursor in this field."
            ),
            secondaries: [.dismissTranscript],
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
            : .newRecording
        let title = context.state == .serverUnavailable
            ? "Gateway unavailable"
            : "Transcription paused"
        // The short line, not the app's paragraph: the fix is on the button
        // beside it, and the detail is in vocaphone for whoever wants it.
        return DictationBarModel(
            title: title,
            body: .message(surfaceLine(for: context.state) ?? "Recording kept."),
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
        secondaries: [.dismiss],
        showsElapsedTime: false,
        isExpanded: true,
        announcement: "Microphone access needed"
    )

    /// A failure that ended the session. Nothing is kept to retry, so the
    /// action is a new recording — drawn as the microphone, because the
    /// circular arrow is Retry's and promises the audio is still there.
    ///
    /// Two of these are not the model's or the gateway's fault, and calling
    /// them "Transcription failed" sent people off to fix the wrong thing: a
    /// recording with no speech in it, and a voice model that is not on this
    /// iPhone. Each gets its own words and the one action that helps.
    private static func permanentFailure(_ context: DictationContext) -> DictationBarModel {
        let failure = DictationFailure(code: context.errorCode)
        let needsModel = failure == .voiceModelMissing
        return DictationBarModel(
            title: failure.keyboardTitle,
            body: .message(failure.keyboardLine),
            accent: needsModel ? .locked : .error,
            pulse: .steady,
            primary: needsModel ? .openVoiceModelSetup : .newRecording,
            secondaries: [.dismiss],
            showsElapsedTime: false,
            isExpanded: true,
            announcement: failure.keyboardTitle
        )
    }

    /// A notice in the status bar, with the keys still up beneath it.
    static func notice(_ notice: DictationNotice) -> DictationBarModel {
        let title: String
        let line: String
        var primary = DictationButton.newRecording
        var accent = DictationAccent.error
        switch notice {
        case .voiceModelNeeded:
            title = DictationFailure.voiceModelMissing.keyboardTitle
            line = DictationFailure.voiceModelMissing.keyboardLine
            primary = .openVoiceModelSetup
            accent = .locked
        case .recordingDidNotStart:
            title = "Recording didn't start"
            line = "The microphone may be busy. Tap Dictate to try again."
        case .handoffTimedOut:
            title = "Dictation didn't start"
            line = "vocaphone didn't answer in time. Tap Dictate to try again."
        case .dictationTimedOut:
            title = "Dictation timed out"
            line = "Nothing came back in time. Tap Dictate to try again."
        case .transcriptExpired:
            title = "Transcript put away"
            line = "It waited too long to insert. It's in Transcripts in vocaphone."
            accent = .working
        }
        return DictationBarModel(
            title: title,
            body: .message(line),
            accent: accent,
            pulse: .steady,
            primary: primary,
            secondaries: [.dismiss],
            showsElapsedTime: false,
            isExpanded: true,
            announcement: "\(title). \(line)"
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
