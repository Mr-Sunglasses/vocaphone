import Foundation

/// Why a dictation ended without text, in the few kinds that need different
/// words — and, more to the point, a different next step.
///
/// The session record carries the app's code and the app's own sentence. That
/// sentence is written for a screen with room to explain, and it is the right
/// thing on Home or the hand-off screen. The keyboard's status bar and the Live
/// Activity have a line each, so they take a short wording from here, keyed by
/// the same code, and the two cannot drift into describing different failures.
enum DictationFailure: Equatable, Sendable {
    /// The recording reached the model and nothing in it was speech. Not a
    /// fault of the model or the gateway, and retrying the same audio cannot
    /// change the answer — a new recording can.
    case noSpeech
    /// On-device transcription is selected and its model is not on this iPhone.
    case voiceModelMissing
    /// The microphone delivered only silence: muted, or taken by another app.
    case microphoneSilenced
    /// The gateway's model cannot transcribe the chosen language.
    case languageUnsupported
    /// Longer than the gateway accepts: the route or gateway changed after
    /// recording began. Kept, so Retry works once either changes back.
    case tooLongForGateway
    case other

    static let noSpeechCode = "no_speech"
    static let voiceModelMissingCode = "local_model_unavailable"
    /// The app could not start the microphone and cancelled the session.
    static let recordingStartFailedCode = "recording_start_failed"
    static let tooLongForGatewayCode = "recording_too_long_for_gateway"

    init(code: String?) {
        switch code {
        case Self.noSpeechCode: self = .noSpeech
        case Self.voiceModelMissingCode: self = .voiceModelMissing
        case "microphone_silenced": self = .microphoneSilenced
        case "language_unsupported": self = .languageUnsupported
        case Self.tooLongForGatewayCode: self = .tooLongForGateway
        default: self = .other
        }
    }

    /// Gateway answers that mean "nothing to transcribe": a finished session
    /// with no text, and the gateway's own verdict on silent audio. Neither is
    /// the gateway failing, so neither is reported as one.
    static func gatewayFoundNoSpeech(code: String) -> Bool {
        code == "empty_transcript" || code == "silent_audio"
    }

    /// The containing app's sentence, for Home and the hand-off screen.
    static let noSpeechMessage =
        "Didn't catch any speech in that recording. Tap Dictate and try again."

    var keyboardTitle: String {
        switch self {
        case .noSpeech: "Didn't catch any speech"
        case .voiceModelMissing: "Voice model needed"
        case .microphoneSilenced: "No sound recorded"
        case .languageUnsupported: "Language not supported"
        case .tooLongForGateway: "Too long for your gateway"
        case .other: "Transcription failed"
        }
    }

    /// One line, under 60 characters, over somebody else's text field.
    var keyboardLine: String {
        switch self {
        case .noSpeech: "Tap Dictate to try again."
        case .voiceModelMissing: "Download one in vocaphone to dictate."
        case .microphoneSilenced: "The microphone was muted or in use."
        case .languageUnsupported: "Pick another language, then dictate."
        case .tooLongForGateway: "Switch to on-device, then tap Retry."
        case .other: "Couldn't transcribe this recording."
        }
    }

    /// What a failed dictation's Live Activity says while it is still up. It
    /// used to be "Needs attention" for everything, which named no problem.
    static func liveActivityStatus(state: SessionState, code: String?) -> String {
        switch state {
        case .serverUnavailable: return "Gateway unreachable · recording kept"
        case .uploadFailedRecoverable: return "Upload failed · recording kept"
        case .transcriptionFailedRecoverable: return "Couldn't transcribe · recording kept"
        default:
            let failure = DictationFailure(code: code)
            return failure == .other ? "Couldn't transcribe" : failure.keyboardTitle
        }
    }
}
