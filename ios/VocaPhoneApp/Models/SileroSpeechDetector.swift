import Foundation

/// Silero VAD through sherpa-onnx, which the app links for its own models
/// anyway. The model is 644 KB and ships in the app bundle, so every on-device
/// route has it, whether or not a sherpa model was ever downloaded.
///
/// Not thread-safe, like the native object it owns: one detector belongs to
/// one dictation's consuming task.
final class SileroSpeechDetector: SpeechActivityDetecting {
    private let native: UnsafeMutableRawPointer

    /// The copy in the app bundle.
    static var bundledModel: URL? {
        Bundle.main.url(forResource: "silero_vad", withExtension: "onnx")
    }

    /// Nil when the model is missing or will not load; callers then carry on
    /// exactly as they did before there was a detector.
    init?(model: URL? = SileroSpeechDetector.bundledModel) {
        // sherpa-onnx ends the process over a model it cannot open rather than
        // returning an error, so a missing file never reaches it.
        guard let model, FileManager.default.fileExists(atPath: model.path) else { return nil }
        let created = model.path.withCString { path in
            VocaPhoneSpeechDetectorCreate(
                path,
                SpeechActivity.threshold,
                SpeechActivity.pauseSeconds,
                SpeechActivity.minimumSpeechSeconds,
                // Longer than any window a model decodes, so the detector never
                // raises its own threshold to force a split mid-sentence.
                30
            )
        }
        guard let created else { return nil }
        native = created
    }

    deinit {
        VocaPhoneSpeechDetectorDestroy(native)
    }

    func accept(_ samples: [Float]) -> [SpeechRegion] {
        guard !samples.isEmpty else { return [] }
        samples.withUnsafeBufferPointer { buffer in
            VocaPhoneSpeechDetectorAccept(native, buffer.baseAddress, Int32(buffer.count))
        }
        return drain()
    }

    func finish() -> [SpeechRegion] {
        VocaPhoneSpeechDetectorFlush(native)
        return drain()
    }

    private func drain() -> [SpeechRegion] {
        var regions: [SpeechRegion] = []
        var start: Int32 = 0
        var end: Int32 = 0
        while VocaPhoneSpeechDetectorNext(native, &start, &end) != 0 {
            if end > start { regions.append(SpeechRegion(start: Int(start), end: Int(end))) }
        }
        return regions
    }
}
