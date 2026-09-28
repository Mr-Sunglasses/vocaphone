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
struct PauseDetector: Sendable {
    /// How long the quiet has to last.
    static let pauseSeconds = 3.0
    /// How much speech has to come first. Without it, a recording started
    /// before the user has gathered their thoughts would end on its own.
    static let minimumSpeechSeconds = 1.0
    /// Speech is this many times the room's floor, and never below
    /// ``minimumSpeechLevel`` (about −42 dBFS).
    static let speechOverFloor: Float = 4
    static let minimumSpeechLevel: Float = 0.008

    /// A level this far under the speech before it — a quarter, about 12 dB
    /// — is quiet whatever it does: room tone, breath, silence.
    static let clearlyUnderSpeech: Float = 4
    /// Between that and half the speech level, level alone cannot tell steady
    /// background from someone carrying on more softly. Movement can: speech
    /// rises and falls with every syllable, a fan or traffic holds its level.
    /// So in that band a level is quiet only if the recent ones held steady,
    /// the loudest within ``steadyRange`` of the quietest.
    static let pauseUnderSpeech: Float = 2
    static let steadyRange: Float = 2
    /// How much recent audio steadiness is judged over: a few syllables. The
    /// pause clock starts once this much steady background has been heard, so
    /// a dictation over background ends about this much later than one in a
    /// silent room.
    static let steadySeconds = 0.6
    // A fan that switches on mid-recording is heard as speech until the floor
    // catches up with it, and in that time it pulls the speech level down to
    // its own; afterwards it is never under half of it, so it can never read
    // as the pause.

    private(set) var floor: Float = 0
    /// How loud the speech has been, a running average of speech levels.
    private(set) var speechLevel: Float = 0
    private(set) var speechSeconds = 0.0
    private(set) var quietSeconds = 0.0
    private(set) var recent: [(level: Float, seconds: Double)] = []

    /// Feeds one level lasting `seconds`. Returns true once the recording
    /// should finish; it keeps returning true after that.
    mutating func observe(rms: Float, seconds: Double) -> Bool {
        let level = max(0, rms)
        recent.append((level, seconds))
        var held = recent.reduce(0) { $0 + $1.seconds }
        while recent.count > 1, held - recent[0].seconds >= Self.steadySeconds {
            held -= recent[0].seconds
            recent.removeFirst()
        }
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
        } else if speechSeconds >= Self.minimumSpeechSeconds, isQuiet(level) {
            quietSeconds += seconds
        } else {
            // Neither speech nor a pause — a sound the floor has absorbed but
            // that is as loud as the talking was, or softer speech still
            // moving like speech. It breaks a quiet stretch.
            quietSeconds = 0
        }
        return speechSeconds >= Self.minimumSpeechSeconds && quietSeconds >= Self.pauseSeconds
    }

    private func isQuiet(_ level: Float) -> Bool {
        if level * Self.clearlyUnderSpeech <= speechLevel { return true }
        guard level * Self.pauseUnderSpeech <= speechLevel,
              let loudest = recent.map(\.level).max(), let quietest = recent.map(\.level).min()
        else { return false }
        return loudest <= max(quietest, Self.minimumSpeechLevel / 100) * Self.steadyRange
    }
}
