import Foundation

/// How long transcripts are kept on this iPhone.
///
/// Surfaced where the retention claim already lives, in Privacy — the product's
/// pitch is that your words stay yours, and "stay" needs a duration.
enum TranscriptRetention: String, CaseIterable, Identifiable, Sendable {
    case forever
    case thirtyDays = "30d"
    case sevenDays = "7d"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forever: "Keep everything"
        case .thirtyDays: "30 days"
        case .sevenDays: "7 days"
        }
    }

    var maximumAge: TimeInterval? {
        switch self {
        case .forever: nil
        case .thirtyDays: 30 * 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        }
    }

    var detail: String {
        switch self {
        case .forever:
            "Transcripts stay until you delete them."
        case .thirtyDays:
            "Transcripts older than 30 days are deleted automatically."
        case .sevenDays:
            "Transcripts older than 7 days are deleted automatically."
        }
    }

    static let `default` = TranscriptRetention.forever

    static func fromStored(_ value: String?) -> TranscriptRetention {
        value.flatMap(TranscriptRetention.init(rawValue:)) ?? .default
    }
}
