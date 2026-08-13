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
    /// loudest sample in what it is given, so feeding it one streaming chunk at
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

        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak >= silencePeak else { return samples }

        // Already loud enough. Attenuating a hot recording cannot undo whatever
        // clipping it arrived with, and quiet is the problem worth solving.
        let gain = min(targetPeak / peak, maximumGain)
        guard gain > 1 else { return samples }

        for index in samples.indices { samples[index] *= gain }
        return samples
    }
}
