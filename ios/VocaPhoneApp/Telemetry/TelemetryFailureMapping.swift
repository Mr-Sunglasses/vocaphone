import Foundation

/// Turns a session failure code into the closed telemetry vocabulary.
///
/// Its own type rather than a method on `RecordingCoordinator` for two reasons:
/// the mapping is pure vocabulary translation with no coordinator state in it,
/// and the coordinator drags the whole audio stack into any target that
/// compiles it — so keeping this separate is what lets the mapping be tested at
/// all.
enum TelemetryFailureMapping {

    /// How far the dictation got, from the failure code.
    ///
    /// Derived from `code` — a closed set this file defines — and never from the
    /// failure message, which is free text and can name a host or a path.
    static func stage(for code: String) -> TelemetryStage {
        switch code {
        case "microphone_permission_denied", "microphone_silenced",
            "recording_start_failed", "audio_missing":
            .capture
        case "gateway_not_configured": .upload
        default: .transcription
        }
    }

    static func reason(for code: String) -> TelemetryReason {
        switch code {
        case "microphone_permission_denied": .permission
        case "microphone_silenced": .audioSilenced
        case "recording_start_failed", "audio_missing": .audio
        case "gateway_not_configured": .gatewayUnreachable
        case "local_transcription_failed": .engineNotReady
        // Unknown rather than the raw code: a code this mapper has not seen is
        // exactly the case where passing it through would put an unreviewed
        // string on the wire.
        default: .unknown
        }
    }
}
