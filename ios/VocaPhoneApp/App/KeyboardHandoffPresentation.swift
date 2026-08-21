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
        case none
    }

    let kind: Kind
    let title: String
    let detail: String
    let primaryAction: PrimaryAction
    let primaryTitle: String?
    let showsCancel: Bool

    /// The handoff applies only to work that began in another app. A session
    /// hosted by vocaphone's practice field has no app to return to.
    static func shouldPresent(_ record: SessionRecord?) -> Bool {
        guard let record,
              record.sourceDocumentID != "in-app-test",
              record.startedInContainingApp != true
        else { return false }

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

        switch record.state {
        case .recording:
            return KeyboardHandoffPresentation(
                kind: .recording,
                title: "Recording",
                detail: "Swipe back to the app where you were typing. Recording keeps going as you switch.",
                primaryAction: .finish,
                primaryTitle: "Finish & transcribe here",
                showsCancel: true
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
                primaryAction: .none,
                primaryTitle: nil,
                showsCancel: true
            )
        case .targetContextChanged:
            return KeyboardHandoffPresentation(
                kind: .ready,
                title: "Your text is ready",
                detail: "Return to the keyboard. Go back to the original field you dictated for, or choose Insert in this field.",
                primaryAction: .none,
                primaryTitle: nil,
                showsCancel: true
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
                showsCancel: true
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
            showsCancel: true
        )
    }
}
