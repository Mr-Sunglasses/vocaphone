import Foundation

/// A stretch of a recording a voice activity detector heard as speech, in
/// samples at 16 kHz counted from the start of the recording.
struct SpeechRegion: Equatable, Sendable {
    let start: Int
    let end: Int
}

/// Finds speech in audio fed to it in recording order.
///
/// A region is only reported once the pause after it has lasted
/// ``SpeechActivity/pauseSeconds``, so being told about one is being told that
/// the speaker has stopped, at least for now. The Silero detector in the app
/// target is the real one; tests stand in their own.
protocol SpeechActivityDetecting: AnyObject {
    /// The regions that closed while taking `samples`.
    func accept(_ samples: [Float]) -> [SpeechRegion]
    /// Closes a region still open at the end of the recording and returns
    /// whatever was left.
    func finish() -> [SpeechRegion]
}

/// What the dictation paths do with the detector's answers.
///
/// Two things, and neither of them is deciding what to throw away on the
/// detector's word alone:
///
/// - **Deciding when to start decoding.** A closed region means the speaker
///   has paused. A model decoding the recording *then* has, very often, the
///   finished transcript waiting by the time Finish is tapped — people stop
///   talking a moment before they reach for the button — and the whole wait
///   after Finish is gone. If they speak again, the early decode is simply not
///   used.
/// - **Trimming the tail.** The pause after the last word, and whatever the
///   phone heard while the user reached for Finish, is audio a model is paid to
///   read and that Whisper, given nothing to hear, fills with "Thank you." It is
///   only cut when the detector heard nothing there *and* nothing in it is loud
///   next to the speech before it, so a last word the detector missed is kept.
enum SpeechActivity {
    static let sampleRate = SherpaLongAudio.sampleRate

    /// How long a pause has to last before the speech before it counts as
    /// finished. Long enough that a breath between words is not a pause; short
    /// enough that the early decode has started before a thumb reaches Finish.
    static let pauseSeconds: Float = 0.5

    /// A sound shorter than this is not speech: a click, a knock.
    static let minimumSpeechSeconds: Float = 0.25

    /// Silero's own default, and the one sherpa-onnx's examples use.
    static let threshold: Float = 0.5

    /// Kept after the last word. A word's tail — a trailing "s", a released
    /// "t" — is quieter than its body and can fall under the detector's
    /// threshold, so the cut is never at the edge of what it heard. Shorter
    /// than ``pauseSeconds``, so everything up to it has been captured by the
    /// time a region is reported.
    static let tailPaddingSamples = sampleRate * 2 / 5

    /// Where a recording can end without losing anything anyone said, or `nil`
    /// to keep all of it.
    ///
    /// - Parameters:
    ///   - samples: the recording, or the part of it still to be decoded.
    ///   - regions: speech the detector found, relative to `samples`.
    ///   - loudestFrameSoFar: the loudest 100 ms frame of anything that came
    ///     before `samples`, as `SherpaLongAudio.loudestFrame` measures it.
    static func trimmedEnd(
        of samples: [Float],
        regions: [SpeechRegion],
        loudestFrameSoFar: Double = 0
    ) -> Int? {
        // A detector that heard no speech anywhere is a detector that cannot be
        // trusted with this recording — a whisper, a far-off microphone — and
        // the whole thing goes to the model exactly as it did before.
        guard let lastEnd = regions.map(\.end).max() else { return nil }
        let end = max(0, min(samples.count, lastEnd + tailPaddingSamples))
        // Less than a frame to gain is not worth a decision.
        guard samples.count - end >= sampleRate / 10 else { return nil }
        let kept = SherpaLongAudio.loudestFrame(Array(samples[..<end]))
        let tail = SherpaLongAudio.loudestFrame(Array(samples[end...]))
        // Anything in the tail loud enough to be speech next to the speech that
        // came before it stays, whatever the detector made of it.
        guard !SherpaLongAudio.carriesSpeech(
            loudestFrame: tail,
            loudestFrameSoFar: max(kept, loudestFrameSoFar)
        ) else { return nil }
        return end
    }

    /// `regions`, moved to be relative to a buffer that begins `offset`
    /// samples into the recording, keeping only what reaches into it.
    static func regions(_ regions: [SpeechRegion], from offset: Int) -> [SpeechRegion] {
        regions.compactMap { region in
            guard region.end > offset else { return nil }
            return SpeechRegion(start: max(0, region.start - offset), end: region.end - offset)
        }
    }
}
