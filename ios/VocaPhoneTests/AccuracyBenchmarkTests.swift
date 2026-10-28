import AVFoundation
import Foundation
import Testing
@preconcurrency import WhisperKit

/// Word error rate on real speech, through the app's own decode paths.
///
/// Not a pass/fail test. It decodes every clip `tools/asr-bench/prepare.py`
/// wrote with one pinned model and writes what the model said, raw and after
/// `DictatedTranscript.finished`, for `tools/asr-bench/score.py` to score.
/// Skipped unless `just accuracy` set it up.
///
/// Two paths, because they fail differently:
///
/// - `file`: a finished recording, as `LocalModelManager.transcribe(audioURL:)`
///   decodes it. Levelled, then Whisper's VAD windows or sherpa's silence
///   chunks.
/// - `streamed`: a dictation, fed a hundred milliseconds at a time to the
///   incremental session the app runs while recording, then finished the way
///   `RecordingCoordinator.finalizeLocally` does.
///
/// A clip already in the results file is skipped, so an interrupted run picks
/// up where it stopped.
@MainActor
@Suite(.serialized, .enabled(if: AccuracyBenchmark.configuration != nil, "set VOCA_ASR_BENCH_DIR; see just accuracy"))
struct AccuracyBenchmarkTests {
    @Test func decodeEverySet() async throws {
        let configuration = try #require(AccuracyBenchmark.configuration)
        for set in configuration.sets {
            let clips = try AccuracyBenchmark.clips(in: set, limit: configuration.limit)
            guard let language = clips.first?.language else { continue }
            guard AccuracyBenchmark.transcribes(configuration.model, language: language) else {
                print("asr-bench: \(configuration.model) does not transcribe \(language); skipping \(set)")
                continue
            }
            for path in configuration.paths {
                try await AccuracyBenchmark.run(configuration, set: set, path: path, clips: clips)
            }
        }
    }
}

@MainActor
enum AccuracyBenchmark {
    struct Configuration {
        let root: URL
        let modelRoot: URL
        let model: String
        let sets: [String]
        let paths: [String]
        let limit: Int?
        let tag: String
    }

    struct Clip: Decodable {
        let id: String
        let file: String
        let seconds: Double
        let language: String
    }

    struct Hypothesis: Encodable {
        let id: String
        let raw: String
        let finished: String
        let milliseconds: Int
        let emptyWindows: Int
    }

    nonisolated static let configuration: Configuration? = {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["VOCA_ASR_BENCH_DIR"],
              let modelRoot = environment["VOCA_ASR_BENCH_MODEL_DIR"],
              let model = environment["VOCA_ASR_BENCH_MODEL"]
        else { return nil }
        func words(_ key: String, _ fallback: String) -> [String] {
            (environment[key] ?? fallback).split(separator: " ").map(String.init)
        }
        return Configuration(
            root: URL(fileURLWithPath: root, isDirectory: true),
            modelRoot: URL(fileURLWithPath: modelRoot, isDirectory: true),
            model: model,
            sets: words("VOCA_ASR_BENCH_SETS", "librispeech-clean librispeech-other librispeech-long fleurs-hi"),
            paths: words("VOCA_ASR_BENCH_PATHS", "file streamed"),
            limit: environment["VOCA_ASR_BENCH_LIMIT"].flatMap(Int.init),
            tag: environment["VOCA_ASR_BENCH_TAG"].flatMap { $0.isEmpty ? nil : $0 } ?? "current"
        )
    }()

    static func clips(in set: String, limit: Int?) throws -> [Clip] {
        let configuration = try #require(configuration)
        let manifest = configuration.root.appendingPathComponent("sets/\(set)/manifest.jsonl")
        let lines = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n")
        let clips = try lines.map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
        return limit.map { Array(clips.prefix($0)) } ?? clips
    }

    static func transcribes(_ model: String, language: String) -> Bool {
        guard let descriptor = LocalModelCatalog.descriptor(for: model) else { return false }
        if descriptor.engine == .whisperKit { return !descriptor.englishOnly || language == "en" }
        let languages = descriptor.selectableLanguageCodes
        return languages.isEmpty || languages.contains(language)
    }

    static func run(_ configuration: Configuration, set: String, path: String, clips: [Clip]) async throws {
        let output = configuration.root
            .appendingPathComponent("results/\(configuration.tag)/\(configuration.model)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let file = output.appendingPathComponent("\(set).\(path).jsonl")
        let done = Set(
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .compactMap { line in
                    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                }
                .compactMap { $0["id"] as? String }
        )
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var decoded = 0
        for clip in clips where !done.contains(clip.id) {
            let samples = try loadSamples(configuration.root.appendingPathComponent("sets/\(set)/\(clip.file)"))
            let started = Date()
            let (raw, emptyWindows) = try await decode(samples, model: configuration.model, language: clip.language, path: path)
            let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
            let finished = DictatedTranscript.finished(
                raw,
                style: .casual,
                language: clip.language,
                repairSpeech: true,
                numbersAsDigits: true,
                spokenEmoji: true,
                snippets: [],
                vocabulary: []
            )
            let hypothesis = Hypothesis(
                id: clip.id, raw: raw, finished: finished,
                milliseconds: milliseconds, emptyWindows: emptyWindows
            )
            try handle.write(contentsOf: encoder.encode(hypothesis) + Data("\n".utf8))
            decoded += 1
        }
        print("asr-bench: \(configuration.model) \(set).\(path): decoded \(decoded), \(done.count) already done")
    }

    private static func decode(
        _ samples: [Float], model: String, language: String, path: String
    ) async throws -> (String, Int) {
        let descriptor = try #require(LocalModelCatalog.descriptor(for: model))
        switch (descriptor.engine, path) {
        case (.whisperKit, "file"): return try await Whisper.file(samples, language: language)
        case (.whisperKit, "streamed"): return try await Whisper.streamed(samples, language: language)
        case (.sherpaOnnx, "file"): return (try Sherpa.file(samples, language: language), 0)
        case (.sherpaOnnx, "streamed"): return (try await Sherpa.streamed(samples, language: language), 0)
        default:
            Issue.record("unknown path \(path)")
            return ("", 0)
        }
    }

    // MARK: - Whisper

    @MainActor
    enum Whisper {
        private static var engine: WhisperKit?

        static func loaded() async throws -> WhisperKit {
            if let engine { return engine }
            let configuration = try #require(AccuracyBenchmark.configuration)
            let model = configuration.model
            let repository = try #require(LocalModelCatalog.descriptor(for: model)?.tokenizerRepository)
            let tokenizerFolder = configuration.modelRoot.appendingPathComponent(
                "Tokenizers/\(repository.replacingOccurrences(of: "/", with: "_"))"
            )
            let loaded = try await WhisperKit(
                WhisperTranscription.engineConfig(
                    model: model,
                    folder: configuration.modelRoot.appendingPathComponent(model),
                    tokenizerFolder: tokenizerFolder,
                    prewarm: false
                )
            )
            engine = loaded
            return loaded
        }

        private static func options(_ language: String) -> DecodingOptions {
            WhisperTranscription.decodingOptions(
                language: language, translate: false, quality: .balanced, promptTokens: nil
            )
        }

        private static func text(_ results: [TranscriptionResult]) -> String {
            results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func file(_ samples: [Float], language: String) async throws -> (String, Int) {
            nonisolated(unsafe) let engine = try await loaded()
            var empty = 0
            let results = try await WhisperTranscription.transcribe(
                samples: SpeechAudioConditioning.condition(samples),
                options: options(language),
                retries: TranscriptionQuality.balanced.whisperRetryCount,
                emptyWindow: { _ in empty += 1 }
            ) {
                try await engine.transcribe(audioArray: $0, decodeOptions: $1)
            }
            return (text(results), empty)
        }

        /// As `ModelEndToEnd.dictateStreaming`: early decodes at each pause into
        /// the dictation's cache, then the trimmed recording at Finish.
        static func streamed(_ captured: [Float], language: String) async throws -> (String, Int) {
            nonisolated(unsafe) let engine = try await loaded()
            let options = options(language)
            let cache = WhisperWindowCache()
            let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            let session = WhisperIncrementalSession(chunks: chunks) {
                SileroSpeechDetector(model: SileroSpeechDetector.repositoryModel)
            } decodeEarly: { prefix in
                let levelled = SpeechAudioConditioning.levelled(prefix)
                _ = try? await WhisperTranscription.transcribe(
                    samples: levelled.samples,
                    options: options,
                    retries: TranscriptionQuality.balanced.whisperRetryCount,
                    cache: cache,
                    levelling: WhisperWindowCache.Levelling(levelled)
                ) {
                    try await engine.transcribe(audioArray: $0, decodeOptions: $1)
                }
            }
            for start in stride(from: 0, to: captured.count, by: 1_600) {
                let chunk = Array(captured[start..<min(captured.count, start + 1_600)])
                continuation.yield(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
            }
            continuation.finish()
            let audio = await session.finish()
            let levelled = SpeechAudioConditioning.levelled(audio.samples)
            var empty = 0
            let results = try await WhisperTranscription.transcribe(
                samples: levelled.samples,
                options: options,
                retries: TranscriptionQuality.balanced.whisperRetryCount,
                cache: cache,
                levelling: WhisperWindowCache.Levelling(levelled),
                emptyWindow: { _ in empty += 1 }
            ) {
                try await engine.transcribe(audioArray: $0, decodeOptions: $1)
            }
            return (text(results), empty)
        }
    }

    // MARK: - sherpa-onnx

    @MainActor
    enum Sherpa {
        private static var loaded: (language: String, recognizer: SherpaRecognizer)?

        /// As `LocalModelManager.ensureSherpaRecognizer` builds it, one per
        /// language, since a language hint is part of the native config.
        static func recognizer(_ language: String) throws -> SherpaRecognizer {
            if let loaded, loaded.language == language { return loaded.recognizer }
            let configuration = try #require(AccuracyBenchmark.configuration)
            let descriptor = try #require(LocalModelCatalog.descriptor(for: configuration.model))
            let family = try #require(descriptor.sherpaFamily)
            let recognizer = try SherpaRecognizer.create(
                model: descriptor,
                directory: configuration.modelRoot.appendingPathComponent(configuration.model),
                language: language,
                threads: SherpaThreads.count,
                quality: family.effectiveQuality(.balanced)
            )
            loaded = (language, recognizer)
            return recognizer
        }

        static func file(_ samples: [Float], language: String) throws -> String {
            let outcome = try recognizer(language).transcribe(SpeechAudioConditioning.condition(samples))
            if let failure = outcome.nativeFailure {
                Issue.record("sherpa decode failed natively: \(failure)")
            }
            return outcome.transcriptOrEmpty.text
        }

        /// As `SherpaEndToEnd.dictation`: streamed while recording, then the
        /// whole file when the stream came back empty or lost a chunk.
        static func streamed(_ captured: [Float], language: String) async throws -> String {
            let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            let session = SherpaIncrementalSession(chunks: chunks, recognizer: try recognizer(language)) {
                SileroSpeechDetector(model: SileroSpeechDetector.repositoryModel)
            }
            for start in stride(from: 0, to: captured.count, by: 1_600) {
                let chunk = Array(captured[start..<min(captured.count, start + 1_600)])
                continuation.yield(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
            }
            continuation.finish()
            let streamed = await session.finish()
            var text = streamed.transcript.text
            if text.isEmpty || streamed.droppedAudibleChunk {
                let wholeFile = try file(captured, language: language)
                if streamed.supersededBy(wholeFile) { text = wholeFile }
            }
            return text
        }
    }

    // MARK: - Audio

    private static func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity))
        try file.read(into: buffer, frameCount: capacity)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
