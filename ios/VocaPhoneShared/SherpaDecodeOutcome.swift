import Foundation

/// Why a native decode produced no transcript.
///
/// These are the engine failing to answer, not the model answering nothing.
/// The distinction is the whole point of the type: the recovery ladder exists
/// to re-ask a model that returned no tokens for audible speech, and re-asking
/// a recognizer whose stream would not open, or whose context is already gone,
/// spends a decode to be told the same thing again.
enum SherpaNativeFailure: String, Sendable, Equatable {
    /// A null or already-destroyed recognizer, or no samples to decode.
    case invalidArgument
    /// sherpa-onnx would not create an offline stream for this recognizer.
    case streamUnavailable
    /// The stream decoded but carried no result object.
    case resultMissing
    /// Text was produced and did not fit the output buffer. The opposite failure
    /// to an empty answer, and the one a smaller window would actually help.
    case outputTruncated
    /// A negative status the bridge does not name. Kept so a future code cannot
    /// be silently read as a successful empty decode.
    case unknown

    /// Maps `VocaPhoneSherpaDecodeStatus`. Lives here rather than at the call
    /// site so the shared target — and its tests — can reason about the values
    /// without importing the bridge.
    static func forStatus(_ status: Int32) -> SherpaNativeFailure {
        switch status {
        case -1: .invalidArgument
        case -2: .streamUnavailable
        case -3: .resultMissing
        case -4: .outputTruncated
        default: .unknown
        }
    }
}

/// What one native decode call did.
///
/// `decoded` covers a genuine empty result: the model was asked and answered
/// nothing. That is an ordinary answer for a pause and the reported failure for
/// speech, and either way it is the model's answer rather than the engine's
/// absence.
enum SherpaDecodeOutcome: Sendable, Equatable {
    case decoded(SherpaTranscript)
    case failed(SherpaNativeFailure)

    static let empty = SherpaDecodeOutcome.decoded(.empty)

    /// The transcript, or an empty one for a failure.
    ///
    /// Only for the paths that genuinely cannot act on the difference. Anything
    /// that decides whether to retry, or what to tell the user, must match on
    /// the case instead — collapsing the two here is the bug this type replaces.
    var transcriptOrEmpty: SherpaTranscript {
        switch self {
        case let .decoded(transcript): transcript
        case .failed: .empty
        }
    }

    var nativeFailure: SherpaNativeFailure? {
        switch self {
        case .decoded: nil
        case let .failed(failure): failure
        }
    }
}
