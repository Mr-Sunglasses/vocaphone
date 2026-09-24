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
        let recognizer = try SherpaEndToEnd.recognizer()
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let session = SherpaIncrementalSession(chunks: chunks, recognizer: recognizer)
        for start in stride(from: 0, to: captured.count, by: 1_600) {
            let chunk = Array(captured[start..<min(captured.count, start + 1_600)])
            continuation.yield(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        continuation.finish()
        let streamed = await session.finish()

        var text = streamed.transcript.text
        if text.isEmpty || streamed.droppedAudibleChunk {
            let wholeFile = try SherpaEndToEnd.wholeFile(SpeechAudioConditioning.condition(captured))
            if streamed.supersededBy(wholeFile) { text = wholeFile }
        }
        let finished = SherpaEndToEnd.finished(text)
        let missing = scenario.markers.filter { !finished.lowercased().contains($0) }
        #expect(missing.isEmpty, "\(scenario.name), streamed: missing \(missing) in “\(finished)”")
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
        // As `LocalModelManager.ensureSherpaRecognizer` builds it.
        let recognizer = try SherpaRecognizer.create(
            model: descriptor,
            directory: try #require(directory),
            language: descriptor.englishOnly ? "en" : "auto",
            threads: max(2, min(ProcessInfo.processInfo.processorCount - 2, 4)),
            quality: family.effectiveQuality(.balanced)
        )
        loaded = recognizer
        return recognizer
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
