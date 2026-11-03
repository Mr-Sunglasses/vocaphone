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
/// A clip that lists a `vocabulary` (the `vocab-en` set) is decoded with it as
/// the user's custom vocabulary: into the decoder the way the app hands it
/// over (Whisper's prompt, Qwen3-ASR's and Parakeet Unified's hotwords), and
/// into the finishing funnel. Every other clip is decoded with none, unless
/// `VOCA_ASR_BENCH_BACKGROUND` names `vocab-en`: then it is decoded with that
/// set's whole term list, which is what ordinary speech meets when a user with
/// a long vocabulary dictates something unrelated to it. Finishing also gets
/// the words the engine was unsure of, as the app passes them, and they are
/// written out as `unsure` (null when the engine reports no confidence).
///
/// `VOCA_ASR_BENCH_FINISH_VOCABULARY` names a file of terms, one per line,
/// that clips without a vocabulary of their own are finished with a second
/// time, as `finishedVocabulary`: the same decode, so the two columns differ
/// only by what correction did to ordinary speech.
///
/// With `VOCA_ASR_BENCH_HINTS=none` no clip gets a vocabulary or anything
/// else. With `VOCA_ASR_BENCH_HINTS=context` no clip gets a vocabulary. Each is
/// decoded instead with the terms `ContextTerms` takes from a text before the
/// cursor (`tools/asr-bench/vocab_en_context.json`): an earlier message in the
/// same thread for a `vocab-en` clip, one unrelated message for every other
/// set. The terms go where the app sends them: the hint list and the finishing
/// funnel's exact-match pass.
///
/// A clip already in the results file is skipped, so an interrupted run picks
/// up where it stopped.
@MainActor
@Suite(.serialized, .enabled(if: AccuracyBenchmark.configuration != nil, "set VOCA_ASR_BENCH_DIR; see just accuracy"))
struct AccuracyBenchmarkTests {
    @Test func decodeEverySet() async throws {
        let configuration = try #require(AccuracyBenchmark.configuration)
        #expect(!AccuracyBenchmark.englishWords.isEmpty, "assets/keyboard/en.txt not found")
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
        /// Balanced unless `VOCA_ASR_BENCH_QUALITY` says otherwise. Fast never
        /// re-samples a window, which makes two runs comparable clip by clip.
        let quality: TranscriptionQuality
        /// The vocabulary a clip without its own is decoded with, as stored
        /// text, or nil for none. See the type's documentation.
        let background: String?
        let backgroundName: String
        /// Terms for `finishedVocabulary`, or nil.
        let finishVocabulary: [String]?
        /// `vocabulary` (the default), `context` or `none`.
        let hints: String
        /// The context texts, read in `context` mode.
        let contexts: Contexts?
    }

    struct Contexts: Decodable {
        let unrelated: String
        let contexts: [String: String]
    }

    struct Clip: Decodable {
        let id: String
        let file: String
        let seconds: Double
        let language: String
        /// The reference transcript.
        let text: String?
        /// The custom vocabulary this dictation is decoded with, one term each,
        /// as the user would have entered them.
        let vocabulary: [String]?

        /// The stored form of the Settings field, which is what the app reads.
        var vocabularyText: String? {
            vocabulary.map { $0.joined(separator: "\n") }
        }
    }

    struct Hypothesis: Encodable {
        let id: String
        let raw: String
        let finished: String
        let milliseconds: Int
        let emptyWindows: Int
        let unsure: [String]?
        let finishedVocabulary: String?
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
        let hints = environment["VOCA_ASR_BENCH_HINTS"].flatMap { $0.isEmpty ? nil : $0 } ?? "vocabulary"
        let contexts = environment["VOCA_ASR_BENCH_CONTEXT"].flatMap { path in
            (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode(Contexts.self, from: $0) }
        }
        return Configuration(
            root: URL(fileURLWithPath: root, isDirectory: true),
            modelRoot: URL(fileURLWithPath: modelRoot, isDirectory: true),
            model: model,
            sets: words("VOCA_ASR_BENCH_SETS", "librispeech-clean librispeech-other librispeech-long fleurs-hi"),
            paths: words("VOCA_ASR_BENCH_PATHS", "file streamed"),
            limit: environment["VOCA_ASR_BENCH_LIMIT"].flatMap(Int.init),
            tag: environment["VOCA_ASR_BENCH_TAG"].flatMap { $0.isEmpty ? nil : $0 } ?? "current",
            quality: environment["VOCA_ASR_BENCH_QUALITY"].flatMap(TranscriptionQuality.init(rawValue:)) ?? .default,
            background: backgroundVocabulary(environment["VOCA_ASR_BENCH_BACKGROUND"] ?? ""),
            backgroundName: environment["VOCA_ASR_BENCH_BACKGROUND"] ?? "",
            finishVocabulary: environment["VOCA_ASR_BENCH_FINISH_VOCABULARY"]
                .flatMap { $0.isEmpty ? nil : try? String(contentsOfFile: $0, encoding: .utf8) }
                .map(CustomVocabulary.terms),
            hints: hints,
            contexts: contexts
        )
    }()

    /// `vocab_en.json`'s whole term list, in its own order, as the stored
    /// Settings text, for `name` "vocab-en"; nil for an empty name.
    nonisolated static func backgroundVocabulary(_ name: String) -> String? {
        guard name == "vocab-en" else {
            precondition(name.isEmpty, "VOCA_ASR_BENCH_BACKGROUND takes only vocab-en")
            return nil
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/asr-bench/vocab_en.json")
        struct Source: Decodable {
            struct Term: Decodable { let term: String }
            let terms: [Term]
        }
        guard let data = try? Data(contentsOf: url),
              let source = try? JSONDecoder().decode(Source.self, from: data)
        else { preconditionFailure("cannot read \(url.path)") }
        return source.terms.map(\.term).joined(separator: "\n")
    }

    /// The vocabulary `clip` is decoded and finished with, as stored text.
    static func vocabularyText(_ clip: Clip) -> String? {
        clip.vocabularyText ?? configuration?.background
    }

    /// What one clip is decoded with: the user's vocabulary, as Settings
    /// stores it, and the terms from around the cursor.
    struct Hints {
        let vocabulary: String?
        let contextTerms: [String]
    }

    static func hints(for clip: Clip, in configuration: Configuration) throws -> Hints {
        switch configuration.hints {
        case "context": break
        case "none": return Hints(vocabulary: nil, contextTerms: [])
        default: return Hints(vocabulary: vocabularyText(clip), contextTerms: [])
        }
        let contexts = try #require(configuration.contexts, "VOCA_ASR_BENCH_CONTEXT is unreadable")
        let before: String = if clip.vocabulary == nil {
            contexts.unrelated
        } else {
            try #require(contexts.contexts[clip.text ?? ""], "no context for \(clip.id)")
        }
        // The earlier message sits above the cursor, as a reply's would.
        let terms = ContextTerms.extract(before: before + "\n", after: nil, isKnownWord: englishWords.contains)
        return Hints(vocabulary: nil, contextTerms: terms)
    }

    static func clips(in set: String, limit: Int?) throws -> [Clip] {
        let configuration = try #require(configuration)
        let manifest = configuration.root.appendingPathComponent("sets/\(set)/manifest.jsonl")
        let lines = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n")
        let clips = try lines.map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
        // Spread across the set, as prepare.py spreads the set across the
        // corpus, so a short run still hears every speaker.
        guard let limit, limit < clips.count else { return clips }
        return (0..<limit).map { clips[$0 * clips.count / limit] }
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
        var settings = ["quality": configuration.quality.rawValue]
        if !configuration.backgroundName.isEmpty { settings["background"] = configuration.backgroundName }
        // The list itself, not its file name: a resume with other terms, or
        // with none where there were some, must not pass as the same control.
        if let terms = configuration.finishVocabulary {
            settings["finishVocabulary"] = terms.joined(separator: "\n")
        }
        if configuration.hints != "vocabulary" { settings["hints"] = configuration.hints }
        try checkSettings(in: output, settings)
        let file = output.appendingPathComponent("\(set).\(path).jsonl")
        try trimIncompleteRecord(file)
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
            let clipHints = try hints(for: clip, in: configuration)
            let result = try await decode(samples, clip: clip, hints: clipHints, model: configuration.model, path: path)
            let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
            let unsure = result.confidence.lowConfidenceWords
            let finished = finish(
                result.text, language: clip.language,
                vocabulary: CustomVocabulary.terms(clipHints.vocabulary), unsure: unsure,
                contextTerms: clipHints.contextTerms
            )
            let finishedVocabulary = clip.vocabulary == nil
                ? configuration.finishVocabulary.map {
                    finish(result.text, language: clip.language, vocabulary: $0, unsure: unsure)
                }
                : nil
            let hypothesis = Hypothesis(
                id: clip.id, raw: result.text, finished: finished,
                milliseconds: milliseconds, emptyWindows: result.emptyWindows,
                unsure: unsure.map { $0.sorted() }, finishedVocabulary: finishedVocabulary
            )
            try handle.write(contentsOf: encoder.encode(hypothesis) + Data("\n".utf8))
            decoded += 1
        }
        print("asr-bench: \(configuration.model) \(set).\(path): decoded \(decoded), \(done.count) already done")
    }

    /// The shipped English word list, read from the repository. The test
    /// bundle has no host app, so `EnglishWords` finds no `en.txt` in it and
    /// would call every word unknown: correction would respell words the app
    /// leaves alone, and the English gate would never open on Automatic.
    static let englishWords: Set<String> = {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/keyboard/en.txt")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).map { $0.lowercased() })
    }()

    /// As the app finishes an on-device dictation, with no replacements.
    static func finish(
        _ raw: String, language: String, vocabulary: [String], unsure: Set<String>?, contextTerms: [String] = []
    ) -> String {
        DictatedTranscript.finished(
            raw,
            style: .casual,
            language: language,
            repairSpeech: true,
            numbersAsDigits: true,
            spokenEmoji: true,
            snippets: [],
            vocabulary: vocabulary,
            replacements: [],
            lowConfidenceWords: unsure,
            isDictionaryWord: englishWords.contains,
            contextTerms: contextTerms
        )
    }

    /// A run resumed with different settings would mix two measurements under
    /// one name, so the settings are written once and every resume must match.
    static func checkSettings(in output: URL, _ settings: [String: String]) throws {
        let file = output.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: file) {
            let recorded = try JSONDecoder().decode([String: String].self, from: data)
            guard recorded == settings else {
                Issue.record("\(output.path) was recorded with \(recorded), not \(settings); use another tag")
                throw CancellationError()
            }
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try encoder.encode(settings).write(to: file)
        }
    }

    /// An interrupted write leaves a last line with no newline. It is cut off
    /// before resuming, so the next record does not run on from it.
    static func trimIncompleteRecord(_ file: URL) throws {
        guard let data = try? Data(contentsOf: file), let last = data.last, last != UInt8(ascii: "\n") else { return }
        let keep = (data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 }) ?? 0
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(keep))
    }

    struct Decoded {
        let text: String
        var emptyWindows = 0
        var confidence: RecognitionConfidence = .unreported
    }

    private static func decode(
        _ samples: [Float], clip: Clip, hints: Hints, model: String, path: String
    ) async throws -> Decoded {
        let descriptor = try #require(LocalModelCatalog.descriptor(for: model))
        let language = clip.language
        switch (descriptor.engine, path) {
        case (.whisperKit, "file"):
            return try await Whisper.file(samples, language: language, hints: hints)
        case (.whisperKit, "streamed"):
            return try await Whisper.streamed(samples, language: language, hints: hints)
        case (.sherpaOnnx, "file"):
            let transcript = try Sherpa.file(samples, language: language, hotwords: Sherpa.hotwords(hints))
            return Decoded(text: transcript.text, confidence: transcript.confidence)
        case (.sherpaOnnx, "streamed"):
            let transcript = try await Sherpa.streamed(
                samples, language: language, hotwords: Sherpa.hotwords(hints)
            )
            return Decoded(text: transcript.text, confidence: transcript.confidence)
        default:
            Issue.record("unknown path \(path)")
            return Decoded(text: "")
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

        static var quality: TranscriptionQuality {
            AccuracyBenchmark.configuration?.quality ?? .default
        }

        /// As `LocalModelManager` builds them for a dictation: from
        /// `WhisperDictationSettings`, with the vocabulary tokenized against
        /// the loaded model.
        private static func options(
            _ language: String, hints: Hints, engine: WhisperKit
        ) -> DecodingOptions {
            let settings = WhisperDictationSettings(
                language: language, translate: false, quality: quality, vocabulary: hints.vocabulary,
                contextTerms: hints.contextTerms
            )
            return settings.decodingOptions(for: engine)
        }

        private static func decoded(_ results: [TranscriptionResult], empty: Int, engine: WhisperKit) -> Decoded {
            Decoded(
                text: results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                emptyWindows: empty,
                confidence: WhisperTranscription.confidence(results, tokenizer: engine.tokenizer)
            )
        }

        static func file(_ samples: [Float], language: String, hints: Hints) async throws -> Decoded {
            nonisolated(unsafe) let engine = try await loaded()
            var empty = 0
            let results = try await WhisperTranscription.transcribe(
                samples: SpeechAudioConditioning.condition(samples),
                options: options(language, hints: hints, engine: engine),
                retries: quality.whisperRetryCount,
                emptyWindow: { _ in empty += 1 }
            ) {
                try await engine.transcribe(audioArray: $0, decodeOptions: $1)
            }
            return decoded(results, empty: empty, engine: engine)
        }

        /// As `LocalModelManager` decodes a dictation: early decodes at each pause
        /// into the dictation's cache, each levelled keeping the gain the last
        /// one settled on, then the trimmed recording at Finish, levelled the
        /// same way.
        static func streamed(_ captured: [Float], language: String, hints: Hints) async throws -> Decoded {
            nonisolated(unsafe) let engine = try await loaded()
            let options = options(language, hints: hints, engine: engine)
            let cache = WhisperWindowCache()
            let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            let session = WhisperIncrementalSession(chunks: chunks) {
                SileroSpeechDetector(model: SileroSpeechDetector.repositoryModel)
            } decodeEarly: { prefix in
                await AccuracyBenchmark.decodeEarly(prefix, cache: cache, options: options, engine: engine)
            }
            for start in stride(from: 0, to: captured.count, by: 1_600) {
                let chunk = Array(captured[start..<min(captured.count, start + 1_600)])
                continuation.yield(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
            }
            continuation.finish()
            let audio = await session.finish()
            let levelled = SpeechAudioConditioning.levelled(audio.samples, keeping: cache.levelling?.kept)
            var empty = 0
            let results = try await WhisperTranscription.transcribe(
                samples: levelled.samples,
                options: options,
                retries: quality.whisperRetryCount,
                cache: cache,
                levelling: WhisperWindowCache.Levelling(levelled),
                emptyWindow: { _ in empty += 1 }
            ) {
                try await engine.transcribe(audioArray: $0, decodeOptions: $1)
            }
            return decoded(results, empty: empty, engine: engine)
        }
    }

    /// `LocalModelManager.decodeEarly`, less the preview.
    private static func decodeEarly(
        _ prefix: [Float], cache: WhisperWindowCache, options: DecodingOptions, engine: WhisperKit
    ) async {
        nonisolated(unsafe) let engine = engine
        let levelled = SpeechAudioConditioning.levelled(prefix, keeping: cache.levelling?.kept)
        let levelling = WhisperWindowCache.Levelling(levelled)
        cache.levelling = levelling
        _ = try? await WhisperTranscription.transcribe(
            samples: levelled.samples,
            options: options,
            retries: Whisper.quality.whisperRetryCount,
            cache: cache,
            levelling: levelling
        ) {
            try await engine.transcribe(audioArray: $0, decodeOptions: $1)
        }
    }

    // MARK: - sherpa-onnx

    @MainActor
    enum Sherpa {
        private static var loaded: (language: String, hotwordSearch: Bool, recognizer: SherpaRecognizer)?

        /// As `LocalModelManager.ensureSherpaRecognizer` builds it: one per
        /// language, since a language hint is part of the native config, and
        /// for a model with a hotword vocabulary, beam search while there are
        /// hotwords and greedy search while there are none.
        static func recognizer(_ language: String, hotwords: String?) throws -> SherpaRecognizer {
            let configuration = try #require(AccuracyBenchmark.configuration)
            let descriptor = try #require(LocalModelCatalog.descriptor(for: configuration.model))
            let vocabulary = hotwords == nil ? nil : hotwordVocabulary(descriptor)
            let hotwordSearch = vocabulary != nil
            if let loaded, loaded.language == language, loaded.hotwordSearch == hotwordSearch {
                return loaded.recognizer
            }
            let family = try #require(descriptor.sherpaFamily)
            // Released before the next is built, as the app does.
            loaded = nil
            let recognizer = try SherpaRecognizer.create(
                model: descriptor,
                directory: configuration.modelRoot.appendingPathComponent(configuration.model),
                language: language,
                threads: SherpaThreads.count,
                quality: family.effectiveQuality(configuration.quality),
                hotwordVocabulary: vocabulary
            )
            loaded = (language, hotwordSearch, recognizer)
            return recognizer
        }

        /// The repository's copy of what the app bundles; see
        /// `LocalModelManager.hotwordVocabulary(for:)`.
        static func hotwordVocabulary(_ descriptor: LocalModelDescriptor) -> URL? {
            descriptor.hotwordVocabularyFile.map { name in
                URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("assets/speech/\(name)")
            }
        }

        /// As `LocalModelManager.sherpaHotwords(for:contextTerms:)` makes them
        /// from the stored vocabulary and the cursor's terms (no replacements).
        static func hotwords(_ hints: Hints) -> String? {
            let configuration = AccuracyBenchmark.configuration
            guard let descriptor = configuration.flatMap({ LocalModelCatalog.descriptor(for: $0.model) })
            else { return nil }
            return RecognitionHints.sherpaHotwords(
                for: descriptor,
                vocabulary: CustomVocabulary.terms(hints.vocabulary),
                replacementTargets: [],
                contextTerms: hints.contextTerms
            )
        }

        static func file(_ samples: [Float], language: String, hotwords: String?) throws -> SherpaTranscript {
            let outcome = try recognizer(language, hotwords: hotwords).transcribe(
                SpeechAudioConditioning.condition(samples), hotwords: hotwords
            )
            if let failure = outcome.nativeFailure {
                Issue.record("sherpa decode failed natively: \(failure)")
            }
            return outcome.transcriptOrEmpty
        }

        /// As `SherpaEndToEnd.dictation`: streamed while recording, then the
        /// whole file when the stream came back empty or lost a chunk.
        static func streamed(
            _ captured: [Float], language: String, hotwords: String?
        ) async throws -> SherpaTranscript {
            let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            let session = SherpaIncrementalSession(
                chunks: chunks, recognizer: try recognizer(language, hotwords: hotwords), hotwords: hotwords
            ) {
                SileroSpeechDetector(model: SileroSpeechDetector.repositoryModel)
            }
            for start in stride(from: 0, to: captured.count, by: 1_600) {
                let chunk = Array(captured[start..<min(captured.count, start + 1_600)])
                continuation.yield(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
            }
            continuation.finish()
            let streamed = await session.finish()
            var transcript = streamed.transcript
            if transcript.text.isEmpty || streamed.droppedAudibleChunk {
                let wholeFile = try file(captured, language: language, hotwords: hotwords)
                if streamed.supersededBy(wholeFile.text) { transcript = wholeFile }
            }
            return transcript
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
