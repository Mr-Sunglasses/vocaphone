import Foundation

/// How much decoding work an on-device model may spend on one dictation.
///
/// This only governs the local engines. The gateway decides for itself, and a
/// phone is where the trade-off actually bites: the same model that finishes a
/// sentence instantly on a desktop can keep an older iPhone busy long enough
/// that the user notices, so the choice belongs to them rather than to a
/// constant somewhere.
///
/// The raw values must stay identical to the Android client's
/// `TranscriptionQuality`, because both write into the same paired setup.
enum TranscriptionQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast
    case balanced
    case accurate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .accurate: "Accurate"
        }
    }

    /// What this setting buys, for the engine it is being shown next to.
    ///
    /// No local engine on this platform searches wider than greedy — WhisperKit
    /// has no beam search at all, and every bundled sherpa family is pinned to
    /// `greedy_search`, see `SherpaFamily.supportsBeamSearch` — so nothing here
    /// may promise that it does. What is left is re-decoding, and that is where
    /// the two engines part company: Whisper re-runs a degenerate window at a
    /// raised temperature and the count comes from this setting, while sherpa's
    /// empty-result recovery is a fixed ladder that does not consult it. Saying
    /// otherwise for sherpa describes a control that currently does nothing.
    func detail(for engine: LocalModelEngine) -> String {
        switch engine {
        case .whisperKit: whisperKitDetail
        case .sherpaOnnx: sherpaDetail
        }
    }

    private var whisperKitDetail: String {
        switch self {
        case .fast: "Quickest result. Skips the retries that rescue a hard passage."
        case .balanced: "Retries a window that comes back empty or looks wrong."
        case .accurate: "Retries hardest before giving up. Noticeably slower on older iPhones."
        }
    }

    private var sherpaDetail: String {
        "This model runs one safe decoding mode, so the accuracy setting does "
            + "not change its result. It applies to Whisper models."
    }

    /// How many times a window whose result looks degenerate — too repetitive,
    /// or too unlikely — is decoded again at a raised temperature.
    ///
    /// This is what catches Whisper's repetition loops, and it costs nothing on
    /// the windows that decode cleanly the first time, which is nearly all of
    /// them. WhisperKit has no beam search, so on this platform it is the whole
    /// of the Whisper trade-off rather than half of it.
    var whisperKitTemperatureFallbackCount: Int {
        switch self {
        case .fast: 0
        case .balanced: 1
        case .accurate: 2
        }
    }

    /// Reaches Whisper's useful temperature range in the bounded pass count
    /// above instead of spending four to six full decoder runs stepping by 0.2.
    var whisperKitTemperatureIncrement: Float {
        switch self {
        case .fast: 0
        case .balanced: 1
        case .accurate: 0.5
        }
    }

    /// What to ask a sherpa model for *if its family supports beam search*.
    ///
    /// No family currently does, so this is unreachable in practice. It stays
    /// because the mapping is the thing to restore once a fixed runtime is
    /// pinned, and because deleting it would leave nothing to restore.
    ///
    /// Never pass this to a recognizer without checking
    /// `SherpaFamily.supportsBeamSearch` first: the families that do not
    /// support it terminate the process rather than falling back.
    var sherpaDecodingMethod: String {
        switch self {
        case .fast: "greedy_search"
        case .balanced, .accurate: "modified_beam_search"
        }
    }

    /// Beam width for `sherpaDecodingMethod`; ignored by `greedy_search`.
    var sherpaMaxActivePaths: Int32 {
        switch self {
        case .fast: 1
        case .balanced: 4
        case .accurate: 8
        }
    }

    /// Balanced rather than fast: the two knobs it turns on are the ones that
    /// pay for themselves, and a first dictation that is wrong is a worse
    /// introduction than one that took an extra moment.
    static let `default` = TranscriptionQuality.balanced

    static func fromStored(_ value: String?) -> TranscriptionQuality {
        value.flatMap(TranscriptionQuality.init(rawValue:)) ?? .default
    }
}
