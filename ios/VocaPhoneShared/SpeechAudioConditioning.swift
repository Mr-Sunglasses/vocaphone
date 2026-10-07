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
        levelled(samples).samples
    }

    /// A levelled recording, and the two numbers that made it what it is.
    struct Levelled: Sendable {
        let samples: [Float]
        /// What every sample was multiplied by: 1 for a recording left alone.
        let gain: Float
        /// The DC offset taken out first, or 0.
        let offset: Float
    }

    /// ``condition(_:)``, saying what it did. Two recordings levelled with the
    /// same gain and offset are, sample for sample, the same audio — which is
    /// what lets a window decoded early be used again at Finish.
    static func levelled(_ samples: [Float]) -> Levelled {
        levelled(samples, keeping: nil)
    }

    /// ``levelled(_:)``, except that while this recording's own gain and offset
    /// stay close to `previous`, `previous` is applied instead.
    ///
    /// A dictation is levelled again every time it grows: once for each early
    /// decode during a pause, and once more at Finish. Both numbers drift as it
    /// does — the gain follows the loudest frames so far, the offset is a mean
    /// over every sample — so the recording levelled at Finish was, sample for
    /// sample, never the audio its early windows were decoded from, and none of
    /// them could be reused. Within ``keptGainDecibels`` and ``keptOffset`` the
    /// difference is far below anything a model hears, and keeping the earlier
    /// numbers keeps the earlier audio. Past them the recording has changed —
    /// a quiet start followed by full-voice speech — and is levelled afresh.
    static func levelled(_ samples: [Float], keeping previous: (gain: Float, offset: Float)?) -> Levelled {
        guard !samples.isEmpty else { return Levelled(samples: samples, gain: 1, offset: 0) }
        var centred = samples

        // A DC offset costs a model headroom and shifts every frame's energy
        // without carrying any of the speech. Some phone inputs have a real one.
        var offset = Float(samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count))
        if abs(offset) > 1e-4 {
            for index in centred.indices { centred[index] -= offset }
        } else {
            offset = 0
        }
        var gain = gain(forLevel: speechLevel(centred))

        if let previous, keeps(previous, gain: gain, offset: offset) {
            // Taken out of the original samples rather than corrected from the
            // measured offset: the same subtraction an earlier pass made gives
            // the same floats, where a correction would round differently.
            if previous.offset != offset {
                centred = samples
                if previous.offset != 0 {
                    for index in centred.indices { centred[index] -= previous.offset }
                }
            }
            gain = previous.gain
            offset = previous.offset
        }
        return Levelled(samples: condition(centred, gain: gain), gain: gain, offset: offset)
    }

    /// How far a recording's own gain may drift from the one kept: a decibel,
    /// about the smallest change in level a listener notices.
    static let keptGainDecibels: Float = 1

    /// How far its offset may: a thousandth of full scale, sixty decibels down.
    static let keptOffset: Float = 1e-3

    private static func keeps(_ previous: (gain: Float, offset: Float), gain: Float, offset: Float) -> Bool {
        guard previous.gain > 0, gain > 0 else { return false }
        return abs(20 * log10(gain / previous.gain)) <= keptGainDecibels
            && abs(offset - previous.offset) <= keptOffset
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
        var level = RunningLevel()
        level.append(samples)
        return level.level
    }

    /// The level of each 20 ms frame, taken from frame maxima.
    static func speechLevel(frameMaxima: [Float]) -> Float {
        guard frameMaxima.count > minimumFrames else { return frameMaxima.max() ?? 0 }
        let frames = frameMaxima.sorted(by: >)
        return frames[min(setAside(audibleFrames: frames.count { $0 >= silencePeak }), frames.count - 1)]
    }

    /// ``speechLevel(_:)`` of everything appended so far, for audio that
    /// arrives a piece at a time.
    ///
    /// The streaming path used to level each chunk by the single loudest sample
    /// captured so far — exactly the measure ``speechLevel(_:)`` replaced on
    /// the whole-file path, because the loudest sample of a dictation is so
    /// often the finger that started it or a knock on the desk. One of those
    /// left every later chunk of quiet speech unlevelled. This keeps the frame
    /// maxima instead — fifty numbers a second — so a chunk is levelled by the
    /// same rule the whole recording would be.
    struct RunningLevel: Sendable {
        static let frameSamples = 320

        private(set) var frameMaxima: [Float] = []
        private var partial: Float = 0
        private var partialCount = 0

        init() {}

        mutating func append(_ samples: [Float]) {
            for sample in samples {
                partial = max(partial, abs(sample))
                partialCount += 1
                if partialCount == Self.frameSamples {
                    frameMaxima.append(partial)
                    partial = 0
                    partialCount = 0
                }
            }
        }

        /// The level of everything appended, the frame still filling included.
        var level: Float {
            guard partialCount > 0 else { return SpeechAudioConditioning.speechLevel(frameMaxima: frameMaxima) }
            return SpeechAudioConditioning.speechLevel(frameMaxima: frameMaxima + [partial])
        }
    }

    /// The gain ``condition(_:peak:)`` applies for a given level: 1 when it
    /// leaves the audio alone, which it does for silence as much as for audio
    /// already loud enough.
    static func gain(forLevel level: Float) -> Float {
        guard level >= silencePeak else { return 1 }
        return max(1, min(targetPeak / level, maximumGain))
    }

    /// How many of the loudest frames to set aside: enough for a knock or a
    /// fumble (sixteen frames, 320 ms), never more than half of the frames
    /// that carry any sound, and at least two.
    ///
    /// A fixed allowance rather than a share. A share of the whole recording
    /// set aside every word of three seconds of speech followed by minutes of
    /// silence; a share of the audible frames did the same to one second of
    /// speech over thirty seconds of room noise. Handling noise is short
    /// whatever the recording's length, so its allowance is too, and half the
    /// audible frames keeps a very short utterance its own level. Noise longer
    /// and louder than 320 ms cannot be told from speech by level alone, and
    /// gets the gain the loudest sample used to give.
    static func setAside(audibleFrames: Int) -> Int {
        max(2, min(maximumSetAside, audibleFrames / 2))
    }

    private static let maximumSetAside = 16

    /// Below this many frames there is too little recording to call anything
    /// in it a transient, and the plain peak decides.
    private static let minimumFrames = 10

    /// Levels `samples` with a gain derived from `peak` rather than from the
    /// slice itself.
    ///
    /// This is how a streaming chunk gets levelled: it passes the
    /// ``RunningLevel`` of everything captured so far, which is the closest one
    /// chunk can come to the single gain `condition` applies over a whole
    /// recording. Passing the slice's own level would be exactly the per-chunk
    /// gain the note above warns against. The DC offset is not touched here — measuring it needs
    /// the whole recording, so it stays on the whole-file path.
    static func condition(_ samples: [Float], peak: Float) -> [Float] {
        condition(samples, gain: gain(forLevel: peak))
    }

    /// Applies a gain ``gain(forLevel:)`` already chose, so audio levelled twice
    /// with the same gain is the same audio.
    static func condition(_ samples: [Float], gain: Float) -> [Float] {
        // Already loud enough. Attenuating a hot recording cannot undo whatever
        // clipping it arrived with, and quiet is the problem worth solving.
        guard !samples.isEmpty, gain > 1 else { return samples }

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
