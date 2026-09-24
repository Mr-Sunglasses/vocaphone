import Foundation
import Testing

/// A real pinned sherpa-onnx model on the same synthesized dictations as
/// `LocalModelEndToEndTests`, through the real recognizer, its C bridge and
/// the same text finishing as the phone.
///
/// Every other sherpa test hands `SherpaLongAudio` and
/// `SherpaIncrementalSession` a decode closure, so the part they cannot see is
/// the model itself: what a runtime or model bump does to real speech, and
/// whether the streaming pass and the whole-file retry still add up to every
/// sentence. Skipped unless `just model-test` has fetched the sherpa model.
@MainActor
@Suite(.serialized, .enabled(if: SherpaEndToEnd.directory != nil, "set VOCA_MODEL_E2E_DIR; see just model-test"))
struct SherpaModelEndToEndTests {

    /// The whole-file path: what `LocalModelManager.transcribe(audioURL:)`
    /// does with a finished recording, and the retry a streaming pass falls
    /// back on.
    @Test(arguments: ModelEndToEnd.scenarios)
    func everySentenceIsTyped(_ scenario: ModelEndToEnd.Scenario) throws {
        let text = try SherpaEndToEnd.finished(
            SherpaEndToEnd.wholeFile(SpeechAudioConditioning.condition(try ModelEndToEnd.samples(scenario)))
        )
        let missing = scenario.markers.filter { !text.lowercased().contains($0) }
        #expect(missing.isEmpty, "\(scenario.name): missing \(missing) in “\(text)”")
    }

    /// What a sherpa dictation actually does: decode while recording, a
    /// hundred milliseconds of capture at a time, then re-decode the file if
    /// the streaming pass came back empty or lost a chunk, as
    /// `RecordingCoordinator.finalizeLocally` does.
    @Test(arguments: ModelEndToEnd.scenarios)
    func streamingDictationKeepsEverySentence(_ scenario: ModelEndToEnd.Scenario) async throws {
        let captured = try ModelEndToEnd.samples(scenario)
        let finished = SherpaEndToEnd.finished(try await SherpaEndToEnd.dictate(captured))
        let missing = scenario.markers.filter { !finished.lowercased().contains($0) }
        #expect(missing.isEmpty, "\(scenario.name), streamed: missing \(missing) in “\(finished)”")
    }

    /// The recorder's own queue refusing chunks: seconds that never reach the
    /// streaming decoder, which it cannot know are missing. The recorder says
    /// so instead (`didDropLocalChunks`), and the finish path must then take
    /// the intact file, as `RecordingCoordinator.finalizeLocally` does.
    @Test func droppedCaptureIsRecoveredFromTheFile() async throws {
        let scenario = try #require(ModelEndToEnd.scenarios.first { $0.name == "two_windows" })
        let captured = try ModelEndToEnd.samples(scenario)
        // Eight seconds from the middle never reach the stream.
        let lost = (12 * 16_000)..<(20 * 16_000)
        let finished = SherpaEndToEnd.finished(
            try await SherpaEndToEnd.dictate(captured, streamLosing: lost)
        )
        let missing = scenario.markers.filter { !finished.lowercased().contains($0) }
        #expect(missing.isEmpty, "dropped capture: missing \(missing) in “\(finished)”")
    }

    /// Continuous speech from many offsets, most of them mid-word, at full and
    /// at a whispered level. None may decode to nothing.
    @Test func noWindowOfSpeechDecodesToNothing() throws {
        let scenario = try #require(ModelEndToEnd.scenarios.first { $0.name == "continuous" })
        let speech = try ModelEndToEnd.samples(scenario)
        var empty: [String] = []
        for gain: Float in [1, 0.12] {
            for step in 0..<16 {
                let start = step * 8_000 + 3_000
                let window = speech[start..<min(speech.count, start + 12 * 16_000)]
                    .enumerated()
                    .map { $0.offset < 3 * 16_000 ? $0.element * gain : $0.element }
                let text = try SherpaEndToEnd.wholeFile(SpeechAudioConditioning.condition(window))
                if text.isEmpty { empty.append("\(Double(start) / 16_000)s ×\(gain)") }
            }
        }
        #expect(empty.isEmpty, "empty windows starting at \(empty)")
    }
}

@MainActor
enum SherpaEndToEnd {
    nonisolated static let model = ProcessInfo.processInfo
        .environment["VOCA_MODEL_E2E_SHERPA_MODEL"] ?? "parakeet-tdt-ctc-110m-en"

    /// Set only when the sherpa model is actually there, so a run that fetched
    /// only Whisper skips this suite rather than failing it.
    nonisolated static let directory: URL? = ModelEndToEnd.directory.flatMap { root in
        let folder = root.appendingPathComponent(model, isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    private static var loaded: SherpaRecognizer?

    static func recognizer() throws -> SherpaRecognizer {
        if let loaded { return loaded }
        let descriptor = try #require(LocalModelCatalog.descriptor(for: model))
        let family = try #require(descriptor.sherpaFamily)
        // The scenarios are English speech with English words to find. A model
        // that does not transcribe English would fail them for no reason that
        // says anything about a regression, so it is refused by name instead.
        let languages = descriptor.selectableLanguageCodes
        try #require(
            languages.isEmpty || languages.contains("en"),
            "\(model) does not transcribe English; pick an English-capable sherpa model"
        )
        // As `LocalModelManager.ensureSherpaRecognizer` builds it.
        let recognizer = try SherpaRecognizer.create(
            model: descriptor,
            directory: try #require(directory),
            language: "en",
            threads: max(2, min(ProcessInfo.processInfo.processorCount - 2, 4)),
            quality: family.effectiveQuality(.balanced)
        )
        loaded = recognizer
        return recognizer
    }

    /// A sherpa dictation end to end: `captured` streamed to the recognizer a
    /// hundred milliseconds at a time while "recording", less any samples in
    /// `streamLosing`, which the recorder's queue refused and reported. Then
    /// the same whole-file decision `RecordingCoordinator.finalizeLocally`
    /// makes, against the intact capture.
    static func dictate(_ captured: [Float], streamLosing lost: Range<Int>? = nil) async throws -> String {
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let session = SherpaIncrementalSession(chunks: chunks, recognizer: try recognizer())
        for start in stride(from: 0, to: captured.count, by: 1_600) {
            if let lost, lost.contains(start) { continue }
            let chunk = Array(captured[start..<min(captured.count, start + 1_600)])
            continuation.yield(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        continuation.finish()
        let streamed = await session.finish()
        let droppedLocalChunks = lost != nil

        var text = streamed.transcript.text
        if text.isEmpty || streamed.droppedAudibleChunk || droppedLocalChunks {
            let wholeFile = try wholeFile(SpeechAudioConditioning.condition(captured))
            if streamed.supersededBy(wholeFile) { text = wholeFile }
        }
        return text
    }

    /// Text, or a thrown failure when the native engine itself refused.
    static func wholeFile(_ samples: [Float]) throws -> String {
        let outcome = try recognizer().transcribe(samples)
        if let failure = outcome.nativeFailure {
            Issue.record("sherpa decode failed natively: \(failure)")
        }
        return outcome.transcriptOrEmpty.text
    }

    static func finished(_ text: String) -> String {
        DictatedTranscript.finished(
            text,
            style: .casual,
            language: "en",
            repairSpeech: true,
            numbersAsDigits: true,
            spokenEmoji: true,
            snippets: []
        )
    }
}
