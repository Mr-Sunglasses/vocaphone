import Foundation

/// Decides when a dictation has ended because the speaker stopped talking.
///
/// Opt-in, because people pause to think in the middle of a sentence and a
/// recording that stops under them is worse than one they have to stop.
/// Deliberately hard to trigger: nothing counts until a full second of speech
/// has been heard, and only an unbroken stretch of quiet after it ends the
/// recording. "Quiet" is judged against the room's own floor, tracked from the
/// levels themselves, so a fan or traffic does not read as speech forever and
/// a silent room does not read as a pause the moment breath is drawn.
///
/// Works on RMS amplitude (0…1). Mirrors `PauseDetector.kt`.
struct PauseDetector: Equatable, Sendable {
    /// How long the quiet has to last.
    static let pauseSeconds = 3.0
    /// How much speech has to come first. Without it, a recording started
    /// before the user has gathered their thoughts would end on its own.
    static let minimumSpeechSeconds = 1.0
    /// Speech is this many times the room's floor, and never below
    /// ``minimumSpeechLevel`` (about −42 dBFS).
    static let speechOverFloor: Float = 4
    static let minimumSpeechLevel: Float = 0.008

    /// A quiet stretch has to sit this far under the speech before it — about
    /// 12 dB. A fan that switches on mid-recording is heard as speech until
    /// the floor catches up with it, and afterwards it is still nowhere near
    /// this far under what was said, so it can never read as the pause.
    static let pauseUnderSpeech: Float = 4

    private(set) var floor: Float = 0
    /// How loud the speech has been, a running average of speech levels.
    private(set) var speechLevel: Float = 0
    private(set) var speechSeconds = 0.0
    private(set) var quietSeconds = 0.0

    /// Feeds one level lasting `seconds`. Returns true once the recording
    /// should finish; it keeps returning true after that.
    mutating func observe(rms: Float, seconds: Double) -> Bool {
        let level = max(0, rms)
        // The floor follows the quietest level down at once and creeps up over
        // about a minute, so a minute of talking barely moves it. A room that
        // gets louder mid-recording is read as speech until the floor catches
        // up — which errs towards not stopping, the safe side.
        if floor == 0 || level < floor {
            floor = level
        } else {
            floor += (level - floor) * Float(seconds) * 0.02
        }
        if level >= max(floor * Self.speechOverFloor, Self.minimumSpeechLevel) {
            speechSeconds += seconds
            quietSeconds = 0
            speechLevel = speechLevel == 0 ? level : speechLevel + (level - speechLevel) * 0.1
        } else if speechSeconds >= Self.minimumSpeechSeconds,
                  level * Self.pauseUnderSpeech <= speechLevel
        {
            quietSeconds += seconds
        } else {
            // Neither speech nor a pause — a sound the floor has absorbed but
            // that is as loud as the talking was. It breaks a quiet stretch.
            quietSeconds = 0
        }
        return speechSeconds >= Self.minimumSpeechSeconds && quietSeconds >= Self.pauseSeconds
    }
}
