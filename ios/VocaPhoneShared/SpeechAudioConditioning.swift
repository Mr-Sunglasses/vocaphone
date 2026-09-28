import Foundation

/// Levels a recording before an on-device model sees it.
///
/// The capture session asks for no automatic gain control, which is the right
/// choice — AGC pumps, and pumping is worse for a recognizer than a quiet
/// signal. The cost is that a phone on a desk or held at arm's length produces
/// a waveform far below the level the models were trained on, and the
/// int8-quantized ones lose real accuracy to that. One fixed gain over the whole
/// recording recovers it without introducing any of the dynamics AGC would.
///
/// This never touches the file on disk or the bytes going to the gateway. It
/// applies to the copy handed to a local engine and nothing else, so a retry
/// against the gateway still sends exactly what the microphone heard.
enum SpeechAudioConditioning {

    /// Enough headroom that no rounding on the way into a model clips.
    private static let targetPeak: Float = 0.85

    /// A ceiling on the boost. Without one, a recording of a closed door becomes
    /// a recording of a room's noise floor at full scale, which models
    /// cheerfully transcribe as words.
    private static let maximumGain: Float = 8

    /// Below this the recording is silence rather than quiet speech — most often
    /// what a microphone another app has taken delivers. Amplifying that would
    /// both manufacture noise and defeat the silence detection that produces a
    /// message the user can act on.
    private static let silencePeak: Float = 0.005

    /// Returns `samples` levelled.
    ///
    /// Only whole recordings should be passed here. The gain is derived from the
    /// ``speechLevel(_:)`` of what it is given, so feeding it one streaming chunk at
    /// a time would apply a different gain to each — jarring across a chunk
    /// boundary, and outright wrong for a chunk that happens to be a pause.
    static func condition(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var samples = samples

        // A DC offset costs a model headroom and shifts every frame's energy
        // without carrying any of the speech. Some phone inputs have a real one.
        let offset = Float(samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count))
        if abs(offset) > 1e-4 {
            for index in samples.indices { samples[index] -= offset }
        }

        return condition(samples, peak: speechLevel(samples))
    }

    /// The level a recording's gain is derived from: its loudest 20 ms frames,
    /// with the very loudest few set aside.
    ///
    /// The single loudest sample used to decide it, and the loudest sample of a
    /// dictation is often not speech: the thump of the finger that tapped Stop,
    /// a knock on the desk, the phone being set down. One of those at 0.9 left
    /// speech at 0.1 exactly where it was, when the recording otherwise earned
    /// eight times the level. Setting aside the loudest 2% of frames (at least
    /// two, so a click that straddles a boundary goes too) takes a transient
    /// out of the decision; real speech keeps nearly all of its level, and the
    /// limiter in ``limited(_:)`` rounds off the peaks that sit above it.
    static func speechLevel(_ samples: [Float]) -> Float {
        let frame = 320
        var frames: [Float] = []
        frames.reserveCapacity(samples.count / frame + 1)
        var start = 0
        while start < samples.count {
            let end = min(start + frame, samples.count)
            var loudest: Float = 0
            for index in start..<end { loudest = max(loudest, abs(samples[index])) }
            frames.append(loudest)
            start = end
        }
        guard frames.count > minimumFrames else { return frames.max() ?? 0 }
        frames.sort(by: >)
        return frames[min(setAside(audibleFrames: frames.count { $0 >= silencePeak }), frames.count - 1)]
    }

    /// How many of the loudest frames to set aside: 5% of the frames that
    /// carry any sound, and at least two.
    ///
    /// Counted over the audible frames only. Counted over the whole recording,
    /// three seconds of quiet speech followed by five minutes of a recorder
    /// left running set aside six seconds of frames — every word — and the
    /// speech got no gain at all. Five percent covers a knock or a fumble as
    /// long as a twentieth of what was said; the level is then the loudest
    /// speech outside that, and ``limited(_:)`` rounds off what sits above it.
    /// Handling noise longer and louder than that cannot be told from speech by
    /// level alone, and gets the gain the loudest sample used to give.
    static func setAside(audibleFrames: Int) -> Int {
        max(2, audibleFrames / 20)
    }

    /// Below this many frames there is too little recording to call anything
    /// in it a transient, and the plain peak decides.
    private static let minimumFrames = 10

    /// Levels `samples` with a gain derived from `peak` rather than from the
    /// slice itself.
    ///
    /// This is how a streaming chunk gets levelled: it passes the peak of every
    /// sample captured so far, which is the closest one chunk can come to the
    /// single gain `condition` applies over a whole recording. Passing the
    /// slice's own peak would be exactly the per-chunk gain the note above
    /// warns against. The DC offset is not touched here — measuring it needs
    /// the whole recording, so it stays on the whole-file path.
    static func condition(_ samples: [Float], peak: Float) -> [Float] {
        guard !samples.isEmpty, peak >= silencePeak else { return samples }

        // Already loud enough. Attenuating a hot recording cannot undo whatever
        // clipping it arrived with, and quiet is the problem worth solving.
        let gain = min(targetPeak / peak, maximumGain)
        guard gain > 1 else { return samples }

        var samples = samples
        for index in samples.indices { samples[index] = limited(samples[index] * gain) }
        return samples
    }

    /// Leaves everything up to the target alone and bends what is above it
    /// smoothly towards full scale, never past it. A transient the level set
    /// aside is amplified with the speech and would otherwise clip; so would a
    /// streaming chunk louder than every one before it.
    static func limited(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > targetPeak else { return sample }
        let headroom = 1 - targetPeak
        let bent = targetPeak + headroom * Float(tanh(Double((magnitude - targetPeak) / headroom)))
        return sample < 0 ? -bent : bent
    }
}
