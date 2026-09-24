import Foundation
import Testing
import WhisperKit

@MainActor
struct WhisperTranscriptionTests {
    private enum Failure: Error { case decoder }

    /// WhisperKit 1.1.0 scores the first-token check on the opening timestamp,
    /// and a window that starts on quiet speech then decodes to empty text
    /// at every temperature. On, this dropped the first window of a dictation.
    @Test(arguments: TranscriptionQuality.allCases)
    func decodingNeverEndsAWindowOnItsFirstTokenAlone(quality: TranscriptionQuality) {
        let options = WhisperTranscription.decodingOptions(
            language: nil,
            translate: false,
            quality: quality,
            promptTokens: nil
        )
        #expect(options.firstTokenLogProbThreshold == nil)
        // The checks that still catch a bad window stay on.
        #expect(options.logProbThreshold != nil)
        #expect(options.compressionRatioThreshold != nil)
        #expect(options.noSpeechThreshold != nil)
        #expect(options.temperatureFallbackCount == quality.whisperKitTemperatureFallbackCount)
    }

    @Test func automaticLanguageAsksForDetection() {
        let automatic = WhisperTranscription.decodingOptions(
            language: nil, translate: false, quality: .balanced, promptTokens: nil
        )
        #expect(automatic.detectLanguage)
        #expect(automatic.task == .transcribe)
        let hindiToEnglish = WhisperTranscription.decodingOptions(
            language: "hi", translate: true, quality: .balanced, promptTokens: [1, 2]
        )
        #expect(!hindiToEnglish.detectLanguage)
        #expect(hindiToEnglish.language == "hi")
        #expect(hindiToEnglish.task == .translate)
        #expect(hindiToEnglish.promptTokens == [1, 2])
    }

    @Test func longRecordingKeepsEverySampleAndDisablesNestedParallelism() async throws {
        let samples = [Float](repeating: 0.2, count: 62 * 16_000 + 100)
        var decodedCount = 0
        var windows = 0
        _ = try await WhisperTranscription.transcribe(
            samples: samples,
            options: DecodingOptions(temperatureFallbackCount: 2, chunkingStrategy: .vad)
        ) { window, options in
            #expect(window.count <= 30 * 16_000)
            #expect(options.concurrentWorkerCount == 1)
            #expect(options.chunkingStrategy == nil)
            #expect(options.temperatureFallbackCount == 2)
            decodedCount += window.count
            windows += 1
            return []
        }
        #expect(decodedCount == samples.count)
        #expect(windows >= 3)
    }

    @Test func laterWindowFailureCannotBecomePartialSuccess() async {
        var windows = 0
        await #expect(throws: Failure.self) {
            _ = try await WhisperTranscription.transcribe(
                samples: [Float](repeating: 0.2, count: 65 * 16_000),
                options: DecodingOptions()
            ) { _, _ in
                windows += 1
                if windows == 2 { throw Failure.decoder }
                return []
            }
        }
        #expect(windows == 2)
    }

    /// Syllable-like bursts over a quiet floor: what speech looks like to an
    /// energy detector, without needing a model.
    private static func speechLike(seconds: Int, level: Float = 0.3) -> [Float] {
        (0..<(seconds * 16_000)).map { index in
            let syllable = (index / 3_200) % 2 == 0
            let tone = sin(Float(index) * 0.2) * (syllable ? level : 0)
            return tone + Float((index * 7_919) % 97 - 48) / 48 * 0.002
        }
    }

    private static func hiss(seconds: Int, level: Float) -> [Float] {
        (0..<(seconds * 16_000)).map { Float(($0 * 7_919) % 97 - 48) / 48 * level }
    }

    private static func said(_ text: String) -> [TranscriptionResult] {
        [TranscriptionResult(text: text, segments: [], language: "en", timings: TranscriptionTimings())]
    }

    @Test func speechThatDecodesToNothingIsReportedWithItsPlace() async throws {
        var reported: [WhisperTranscription.EmptyWindow] = []
        var window = 0
        let results = try await WhisperTranscription.transcribe(
            samples: Self.speechLike(seconds: 45),
            options: DecodingOptions(),
            emptyWindow: { reported.append($0) }
        ) { _, _ in
            defer { window += 1 }
            // The first window comes back blank, as WhisperKit 1.1.0 did.
            return window == 0 ? Self.said("  ") : Self.said("the rest of it")
        }
        #expect(results.count == 2)
        #expect(reported.count == 1)
        #expect(reported.first?.index == 0)
        #expect(reported.first?.count == 2)
        #expect((reported.first?.milliseconds ?? 0) > 15_000)
    }

    /// Speech with no pause anywhere: four syllables a second, each a 150 ms
    /// vowel and a 100 ms consonant some 23 dB quieter, never falling silent.
    /// That is the swing measured in the model tests' continuous speech, where
    /// the loud frames sit 12 to 16 times above the quiet ones.
    private static func unbrokenSpeech(seconds: Int) -> [Float] {
        (0..<(seconds * 16_000)).map { index in
            let vowel = index % 4_000 < 2_400
            return sin(Float(index) * 0.2) * (vowel ? 0.3 : 0.02)
        }
    }

    /// No quiet frames to measure a floor from; the window must still count
    /// as speech.
    @Test func continuousSpeechThatDecodesToNothingIsReported() async throws {
        let unbroken = Self.unbrokenSpeech(seconds: 20)
        #expect(WhisperTranscription.soundsLikeSpeech(unbroken))
        var reported = 0
        _ = try await WhisperTranscription.transcribe(
            samples: unbroken,
            options: DecodingOptions(),
            emptyWindow: { _ in reported += 1 }
        ) { _, _ in [] }
        #expect(reported == 1)
    }

    /// Steady room hiss as the decoder receives it: through the app's own
    /// levelling, which boosts a quiet recording up to eight times. Loud as
    /// that makes it, it never moves, and it must not be reported.
    @Test(arguments: [Float(0.002), 0.005, 0.01])
    func levelledRoomHissIsNotReported(level: Float) async throws {
        let hiss = SpeechAudioConditioning.condition(Self.hiss(seconds: 12, level: level))
        #expect(!WhisperTranscription.soundsLikeSpeech(hiss))
        var reported = 0
        _ = try await WhisperTranscription.transcribe(
            samples: hiss,
            options: DecodingOptions(),
            emptyWindow: { _ in reported += 1 }
        ) { _, _ in [] }
        #expect(reported == 0)
    }

    @Test func silenceThatDecodesToNothingIsNotReported() async throws {
        var reported = 0
        _ = try await WhisperTranscription.transcribe(
            samples: Self.hiss(seconds: 10, level: 0.002),
            options: DecodingOptions(),
            emptyWindow: { _ in reported += 1 }
        ) { _, _ in [] }
        #expect(reported == 0)
    }

    /// The app multiplies a quiet recording by up to eight before decoding, which
    /// puts room hiss well above any fixed level. It is still not speech.
    @Test func levelledHissIsNotMistakenForSpeech() {
        #expect(!WhisperTranscription.soundsLikeSpeech(Self.hiss(seconds: 10, level: 0.02)))
        #expect(WhisperTranscription.soundsLikeSpeech(Self.speechLike(seconds: 10, level: 0.05)))
    }

    @Test func shortFinalWindowIsNotSkippedByWhisperSeekPadding() async throws {
        var calls = 0
        var speechSamples = 0
        _ = try await WhisperTranscription.transcribe(
            samples: [Float](repeating: 0.2, count: 30 * 16_000 + 4_000),
            options: DecodingOptions()
        ) { window, options in
            calls += 1
            speechSamples += window.filter { $0 != 0 }.count
            #expect(window.count > Int(options.windowClipTime * 16_000))
            return []
        }
        #expect(calls == 2)
        #expect(speechSamples == 30 * 16_000 + 4_000)
    }

    /// Stands in for WhisperKit: which build it is, so a test can tell whether
    /// a window ran on the first engine or the rebuilt one.
    private struct Engine { let build: Int }

    /// Two full windows and a third, so a failure can land after work that
    /// already succeeded.
    private let threeWindows = [Float](repeating: 0.2, count: 65 * 16_000)

    @Test func windowFailureResumesAtThatWindowOnAFreshEngine() async throws {
        var baseline: [Int] = []
        _ = try await WhisperTranscription.transcribe(samples: threeWindows) {
            Engine(build: 1)
        } options: { _ in
            DecodingOptions()
        } discard: { _ in
        } decode: { _, window, _ in
            baseline.append(window.count)
            return []
        }
        #expect(baseline.count >= 3)

        var loads = 0
        var discards = 0
        var calls: [(build: Int, samples: Int)] = []
        _ = try await WhisperTranscription.transcribe(samples: threeWindows) {
            loads += 1
            return Engine(build: loads)
        } options: { _ in
            DecodingOptions()
        } discard: { _ in
            discards += 1
        } decode: { engine, window, _ in
            calls.append((engine.build, window.count))
            if calls.count == 2 { throw Failure.decoder }
            return []
        }
        #expect(loads == 2)
        #expect(discards == 1)
        // The first window once, on the first engine. The second failed there
        // and ran again on the rebuilt one; everything after it only on that.
        #expect(calls.map(\.build) == [1, 1] + Array(repeating: 2, count: baseline.count - 1))
        #expect(calls.map(\.samples) == [baseline[0], baseline[1]] + baseline.dropFirst())
    }

    @Test func loadFailureIsRetriedOnce() async throws {
        var loads = 0
        var discards = 0
        var builds: Set<Int> = []
        _ = try await WhisperTranscription.transcribe(samples: threeWindows) {
            loads += 1
            if loads == 1 { throw Failure.decoder }
            return Engine(build: loads)
        } options: { _ in
            DecodingOptions()
        } discard: { _ in
            discards += 1
        } decode: { engine, _, _ in
            builds.insert(engine.build)
            return []
        }
        #expect(loads == 2)
        #expect(discards == 1)
        #expect(builds == [2])
    }

    @Test func onlyOneRebuildPerRecording() async {
        var loads = 0
        var decodes = 0
        // The load spends the rebuild, so a later window failure is final.
        await #expect(throws: Failure.self) {
            _ = try await WhisperTranscription.transcribe(samples: threeWindows) {
                loads += 1
                if loads == 1 { throw Failure.decoder }
                return Engine(build: loads)
            } options: { _ in
                DecodingOptions()
            } discard: { _ in
            } decode: { _, _, _ in
                decodes += 1
                if decodes == 2 { throw Failure.decoder }
                return []
            }
        }
        #expect(loads == 2)
        #expect(decodes == 2)
    }

    @Test func failureOnTheRebuiltEngineIsNotHidden() async {
        var loads = 0
        await #expect(throws: Failure.self) {
            _ = try await WhisperTranscription.transcribe(samples: threeWindows) {
                loads += 1
                return Engine(build: loads)
            } options: { _ in
                DecodingOptions()
            } discard: { _ in
            } decode: { _, _, _ in
                throw Failure.decoder
            }
        }
        #expect(loads == 2)
    }

    @Test func cancellationIsNeverRetried() async {
        var loads = 0
        var discards = 0
        await #expect(throws: CancellationError.self) {
            _ = try await WhisperTranscription.transcribe(samples: threeWindows) {
                loads += 1
                return Engine(build: loads)
            } options: { _ in
                DecodingOptions()
            } discard: { _ in
                discards += 1
            } decode: { _, _, _ in
                throw CancellationError()
            }
        }
        #expect(loads == 1)
        #expect(discards == 0)
    }
}
