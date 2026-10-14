import Foundation

/// A full-screen explanation for an externally started dictation. It follows
/// the persisted session, rather than only live recording, so finishing in
/// vocaphone stays a continuous story through transcription and insertion.
struct KeyboardHandoffPresentation: Equatable {
    enum Kind: Equatable {
        case recording
        case processing
        case ready
        case recoverableFailure
    }

    enum PrimaryAction: Equatable {
        case finish
        case retry
        /// The transcript to the clipboard, for whoever would rather paste it
        /// than go back to the keyboard for it.
        case copyTranscript
        case none
    }

    let kind: Kind
    let title: String
    let detail: String
    let primaryAction: PrimaryAction
    let primaryTitle: String?
    let showsCancel: Bool
    /// A way to Home that leaves the session as it is: a waiting transcript
    /// stays waiting for the keyboard, a failed one keeps its recording.
    /// Without it, the only way past this screen while a transcript waited
    /// was Cancel dictation — the app was unusable for up to an hour.
    var showsNotNow = false
    /// The recording clock, counted from when the microphone started.
    var showsElapsedTime = false

    /// The handoff applies only to work that began in another app. A session
    /// hosted by vocaphone's practice field has no app to return to.
    static func shouldPresent(_ record: SessionRecord?) -> Bool {
        guard let record,
              record.sourceDocumentID != "in-app-test",
              record.startedInContainingApp != true
        else { return false }

        // The wait for the app to come up belongs to the hand-off, not to the
        // home screen. Presenting from `launchingApp` is what makes the app
        // open *on* the swipe-back screen instead of painting its home screen
        // for a frame and then covering it. A hand-off nobody claimed is
        // retired by `SessionExpiryPolicy`, but a record that is already past
        // its window must not put this screen up on an ordinary launch.
        if record.state == .launchingApp || record.state == .awaitingReturn {
            return !SessionExpiryPolicy.isStale(record)
        }

        return switch record.state {
        case .recording, .finalizing, .uploading, .transcribing, .readyToInsert,
             .targetContextChanged, .serverUnavailable, .uploadFailedRecoverable,
             .transcriptionFailedRecoverable:
            true
        default:
            false
        }
    }

    static func make(_ record: SessionRecord) -> KeyboardHandoffPresentation? {
        guard shouldPresent(record) else { return nil }

        // The cap ended the recording, not a tap, so the last sentence may be
        // cut off. Said for the whole wait, as the keyboard says it.
        if record.stoppedAtRecordingLimit == true,
           [.finalizing, .uploading, .transcribing].contains(record.state)
        {
            return processing(title: DictationBarModel.recordingLimitTitle)
        }

        switch record.state {
        // One screen from the moment the app is asked for until the transcript
        // exists: the request is the same request whether the recorder has
        // caught up yet or not, and swapping layouts underneath the user while
        // they are reading is what made this feel like three separate steps.
        case .launchingApp, .awaitingReturn, .recording:
            // A quiet Cancel, for whoever tapped Dictate by mistake: the Live
            // Activity and the keyboard both have one, but neither is on
            // this screen.
            return KeyboardHandoffPresentation(
                kind: .recording,
                title: "Swipe back to your app",
                detail: "Recording follows you there.",
                primaryAction: .none,
                primaryTitle: nil,
                showsCancel: true,
                showsElapsedTime: record.state == .recording
            )
        case .finalizing:
            return processing(title: "Finishing recording")
        case .uploading:
            switch record.processingLocation {
            case .gateway:
                return processing(title: "Sending to your gateway")
            case .onDevice:
                return processing(title: "Preparing on this iPhone")
            case nil:
                return processing(title: "Preparing transcript")
            }
        case .transcribing:
            switch record.processingLocation {
            case .gateway:
                return processing(title: "Transcribing on your gateway")
            case .onDevice:
                return processing(title: "Transcribing on this iPhone")
            case nil:
                return processing(title: "Transcribing")
            }
        case .readyToInsert:
            return KeyboardHandoffPresentation(
                kind: .ready,
                title: "Your text is ready",
                detail: "Return to the keyboard and tap Insert.",
                primaryAction: hasTranscript(record) ? .copyTranscript : .none,
                primaryTitle: hasTranscript(record) ? "Copy text" : nil,
                showsCancel: true,
                showsNotNow: true
            )
        case .targetContextChanged:
            return KeyboardHandoffPresentation(
                kind: .ready,
                title: "Your text is ready",
                detail: "Return to the keyboard. Go back to the original field you dictated for, or tap Insert here.",
                primaryAction: hasTranscript(record) ? .copyTranscript : .none,
                primaryTitle: hasTranscript(record) ? "Copy text" : nil,
                showsCancel: true,
                showsNotNow: true
            )
        case .serverUnavailable, .uploadFailedRecoverable, .transcriptionFailedRecoverable:
            return KeyboardHandoffPresentation(
                kind: .recoverableFailure,
                title: record.state == .serverUnavailable
                    ? "Gateway unavailable"
                    : "Transcription paused",
                detail: record.error?.message ?? "Your recording is preserved. Return when you are ready to retry.",
                primaryAction: record.canRetry ? .retry : .none,
                primaryTitle: record.canRetry ? "Retry transcript" : nil,
                showsCancel: true,
                showsNotNow: true
            )
        default:
            return nil
        }
    }

    private static func processing(title: String) -> KeyboardHandoffPresentation {
        KeyboardHandoffPresentation(
            kind: .processing,
            title: title,
            detail: "You can return to the app where you were typing. The keyboard will update there.",
            primaryAction: .none,
            primaryTitle: nil,
            showsCancel: true,
            showsNotNow: true
        )
    }

    private static func hasTranscript(_ record: SessionRecord) -> Bool {
        record.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

/// What the swipe-back screen asks for, on the phone it is running on.
///
/// The drawn gesture is a swipe along the home indicator, and an iPhone with a
/// Home button has no home indicator to swipe — it was being taught a gesture
/// it does not have. Every iPhone does have the "◀ App" button iOS puts at the
/// top-left when one app opens another, so that is offered to everyone, and is
/// the whole instruction on a Home-button iPhone.
struct SwipeBackGuidance: Equatable {
    let title: String
    let detail: String
    let alternative: String
    /// Draw the swipe along the bottom edge, or the top-left button.
    let showsSwipe: Bool

    static func make(
        hasHomeIndicator: Bool,
        title: String,
        detail: String
    ) -> SwipeBackGuidance {
        guard hasHomeIndicator else {
            return SwipeBackGuidance(
                title: title.hasPrefix("Swipe back")
                    ? "Go back" + title.dropFirst("Swipe back".count)
                    : title,
                detail: detail,
                alternative: "Tap ◀ at the top-left of the screen, or press the Home button twice and choose it.",
                showsSwipe: false
            )
        }
        return SwipeBackGuidance(
            title: title,
            detail: detail,
            alternative: "Or tap ◀ at the top-left of the screen.",
            showsSwipe: true
        )
    }
}
