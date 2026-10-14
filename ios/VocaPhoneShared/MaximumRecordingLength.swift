import Foundation

/// How long one dictation may record before it finishes on its own.
///
/// The bound exists so a forgotten recording does not run until the phone
/// runs out of space. The right length is personal: a quick reply needs a
/// minute, a dictated email or a note can need several. The setting is the
/// only place a duration is shown — no surface counts the recording up or
/// down, by design.
enum MaximumRecordingLength: String, CaseIterable, Identifiable, Sendable {
    case oneMinute
    case twoMinutes
    case fiveMinutes
    case tenMinutes

    static let `default`: MaximumRecordingLength = .fiveMinutes

    /// The longest choice. Anything sized for "the whole recording" — the
    /// keyboard's expiry for a live recording, the streamed upload's deadline —
    /// is sized for this, because the keyboard cannot know which was chosen.
    static let longest: MaximumRecordingLength = .tenMinutes

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .oneMinute: 60
        case .twoMinutes: 2 * 60
        case .fiveMinutes: 5 * 60
        case .tenMinutes: 10 * 60
        }
    }

    var displayName: String {
        switch self {
        case .oneMinute: "1 minute"
        case .twoMinutes: "2 minutes"
        case .fiveMinutes: "5 minutes"
        case .tenMinutes: "10 minutes"
        }
    }
}

/// The cap a recording actually gets, from the setting and the route.
///
/// On this iPhone the setting is the whole answer. A gateway enforces its own
/// limit and refuses longer audio, so on that route the smaller of the two
/// wins; a gateway that has never reported one is an older one, which accepts
/// two minutes, and is treated as exactly that so no recording it receives is
/// refused for its length.
enum RecordingLengthLimit {
    /// What a gateway that predates `maximum_duration_seconds` accepts.
    static let unreportedGatewaySeconds: TimeInterval = 120

    static func effectiveSeconds(
        choice: MaximumRecordingLength,
        location: SessionProcessingLocation,
        gatewayReportedSeconds: Int?
    ) -> TimeInterval {
        switch location {
        case .onDevice:
            return choice.seconds
        case .gateway:
            return min(choice.seconds, gatewayLimit(gatewayReportedSeconds))
        }
    }

    /// The one line Settings shows when the gateway will stop a recording
    /// sooner than the user asked for. `nil` when it will not.
    static func gatewayNote(
        choice: MaximumRecordingLength,
        gatewayReportedSeconds: Int?
    ) -> String? {
        let limit = gatewayLimit(gatewayReportedSeconds)
        guard limit < choice.seconds else { return nil }
        return "Your gateway accepts up to \(phrase(for: limit)). "
            + "Update the gateway to record longer."
    }

    private static func gatewayLimit(_ reported: Int?) -> TimeInterval {
        // A zero or negative value is not a limit anyone set on purpose.
        guard let reported, reported > 0 else { return unreportedGatewaySeconds }
        return TimeInterval(reported)
    }

    /// "2 minutes", "90 seconds", "1 minute".
    static func phrase(for seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        if whole % 60 == 0 {
            let minutes = whole / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return whole == 1 ? "1 second" : "\(whole) seconds"
    }
}
