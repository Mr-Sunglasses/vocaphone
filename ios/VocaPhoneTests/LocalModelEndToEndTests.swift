import AVFAudio
import Foundation
import Testing
import WhisperKit

/// A real Whisper model on real audio, through the same levelling, windowing,
/// decode options and text finishing as a dictation on the phone.
///
/// Every other test of this path stands a closure in for WhisperKit, which is
/// how the WhisperKit 1.1.0 upgrade shipped a decoder that returned an empty
/// first window for a dictation that opened quietly: nothing in the suite ever
/// decoded a word. These tests would have failed on that upgrade's pull request.
///
/// They need a downloaded model and synthesized audio, so they are skipped
/// unless `VOCA_MODEL_E2E_DIR` is set. `just model-test` fetches the pinned
/// model, speaks the scenarios and sets it. See `tools/model-e2e/`.
@MainActor
@Suite(.serialized, .enabled(if: ModelEndToEnd.directory != nil, "set VOCA_MODEL_E2E_DIR; see just model-test"))
struct LocalModelEndToEndTests {

    @Test(arguments: ModelEndToEnd.scenarios)
    func everySentenceIsTyped(_ scenario: ModelEndToEnd.Scenario) async throws {
        let text = try await ModelEndToEnd.dictate(scenario)
        let missing = scenario.markers.filter { !text.lowercased().contains($0) }
        #expect(missing.isEmpty, "\(scenario.name): missing \(missing) in “\(text)”")
    }

    /// Where a decoding window starts is up to the silence splitter, and in
    /// continuous speech that is mid-word as often as not. WhisperKit 1.1.0
    /// ended some of those windows on their first token and returned nothing,
    /// so every offset here, at full and at a whispered level, must produce
    /// text. Without the fix, about one in four windows came back empty.
    @Test func noWindowOfSpeechDecodesToNothing() async throws {
        let scenario = try #require(ModelEndToEnd.scenarios.first { $0.name == "continuous" })
        let speech = try ModelEndToEnd.samples(scenario)
        var empty: [String] = []
        for gain: Float in [1, 0.12] {
            for step in 0..<16 {
                // Every half second, off any word boundary the voice keeps.
                let start = step * 8_000 + 3_000
                let window = speech[start..<min(speech.count, start + 12 * 16_000)]
                    .enumerated()
                    // The first three seconds at `gain`: a window that opens quiet.
                    .map { $0.offset < 3 * 16_000 ? $0.element * gain : $0.element }
                let text = try await ModelEndToEnd.decode(SpeechAudioConditioning.condition(window))
                if text.isEmpty { empty.append("\(Double(start) / 16_000)s ×\(gain)") }
            }
        }
        #expect(empty.isEmpty, "empty windows starting at \(empty)")
    }

    /// Custom vocabulary reaches Whisper as prompt tokens, which is the path
    /// WhisperKit fixed an empty-transcript bug on in 1.1.0.
    @Test func customVocabularyDoesNotEmptyTheTranscript() async throws {
        let scenario = try #require(ModelEndToEnd.scenarios.first { $0.name == "two_windows" })
        let text = try await ModelEndToEnd.dictate(scenario, vocabulary: "VocaPhone, Kanishk, WhisperKit")
        let missing = scenario.markers.filter { !text.lowercased().contains($0) }
        #expect(missing.isEmpty, "with vocabulary: missing \(missing) in “\(text)”")
    }
}

@MainActor
enum ModelEndToEnd {
    struct Scenario: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let file: String
        let seconds: Double
        let markers: [String]

        var testDescription: String { "\(name) (\(seconds)s)" }
    }

    nonisolated static let directory: URL? = ProcessInfo.processInfo
        .environment["VOCA_MODEL_E2E_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    nonisolated static let model = ProcessInfo.processInfo
        .environment["VOCA_MODEL_E2E_MODEL"] ?? "openai_whisper-small_216MB"

    nonisolated static let scenarios: [Scenario] = {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("scenarios/scenarios.json"))
        else { return [] }
        return (try? JSONDecoder().decode([Scenario].self, from: data)) ?? []
    }()

    /// One engine for the whole run, as the app keeps one between dictations.
    private static var engine: WhisperKit?

    private static func loadedEngine() async throws -> WhisperKit {
        if let engine { return engine }
        let directory = try #require(directory)
        // The folder the app itself keeps this model's tokenizer in.
        let repository = try #require(LocalModelCatalog.descriptor(for: model)?.tokenizerRepository)
        let tokenizerFolder = directory.appendingPathComponent(
            "Tokenizers/\(repository.replacingOccurrences(of: "/", with: "_"))"
        )
        let loaded = try await WhisperKit(
            WhisperTranscription.engineConfig(
                model: model,
                folder: directory.appendingPathComponent(model),
                tokenizerFolder: tokenizerFolder,
                prewarm: false
            )
        )
        engine = loaded
        return loaded
    }

    static func samples(_ scenario: Scenario) throws -> [Float] {
        let directory = try #require(directory)
        return try loadSamples(directory.appendingPathComponent("scenarios/\(scenario.file)"))
    }

    /// One recording through the app's windowing and options, as text.
    static func decode(_ samples: [Float]) async throws -> String {
        let engine = try await loadedEngine()
        let options = WhisperTranscription.decodingOptions(
            language: nil, translate: false, quality: .balanced, promptTokens: nil
        )
        return try await WhisperTranscription.transcribe(samples: samples, options: options) {
            try await engine.transcribe(audioArray: $0, decodeOptions: $1)
        }
        .map(\.text).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What `LocalModelManager.transcribe(audioURL:language:)` does with a
    /// finished recording, then what the keyboard is handed to type.
    static func dictate(_ scenario: Scenario, vocabulary: String? = nil) async throws -> String {
        let samples = SpeechAudioConditioning.condition(try Self.samples(scenario))
        let prompt = CustomVocabulary.whisperPrompt(vocabulary)
        let results = try await WhisperTranscription.transcribe(samples: samples) {
            try await loadedEngine()
        } options: { engine in
            WhisperTranscription.decodingOptions(
                language: nil,
                translate: false,
                quality: .balanced,
                promptTokens: prompt.isEmpty ? nil : engine.tokenizer?.encode(text: prompt)
            )
        } discard: { _ in
            engine = nil
        } emptyWindow: { window in
            // The diagnostics line a phone would write. Real speech must never
            // trip it, and a window that really decoded to nothing must.
            Issue.record("\(scenario.name): window \(window.index + 1) of \(window.count) decoded to nothing")
        } decode: { engine, window, options in
            try await engine.transcribe(audioArray: window, decodeOptions: options)
        }
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DictatedTranscript.finished(
            text,
            style: .casual,
            language: "en",
            repairSpeech: true,
            numbersAsDigits: true,
            spokenEmoji: true,
            snippets: []
        )
    }

    private static func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity))
        try file.read(into: buffer, frameCount: capacity)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
