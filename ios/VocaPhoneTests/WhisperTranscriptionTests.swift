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
        // WhisperKit's fallback keeps its last attempt; the window loop's
        // keeps the best, so WhisperKit's is off at every setting.
        #expect(options.temperatureFallbackCount == 0)
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

    /// Automatic detects once, like whisper.cpp: a mixed-language dictation
    /// must not switch script from one window to the next.
    @Test func automaticLanguageIsDecidedOncePerRecording() async throws {
        var seen: [(language: String?, detects: Bool?)] = []
        _ = try await WhisperTranscription.transcribe(
            samples: Self.speechLike(seconds: 70),
            options: WhisperTranscription.decodingOptions(
                language: nil, translate: false, quality: .balanced, promptTokens: nil
            )
        ) { _, options in
            seen.append((options.language, options.detectLanguage))
            return [TranscriptionResult(text: "namaste", segments: [], language: "hi", timings: TranscriptionTimings())]
        }
        #expect(seen.count >= 3)
        #expect(seen.first?.language == nil)
        #expect(seen.first?.detects == true)
        for later in seen.dropFirst() {
            #expect(later.language == "hi")
            #expect(later.detects == false)
        }
    }

    /// Through the window loop: a blank first window leaves detection on, and
    /// the first window with words decides every window after it.
    @Test func aBlankFirstWindowLeavesTheDecisionToTheNext() async throws {
        var seen: [(language: String?, detects: Bool?)] = []
        _ = try await WhisperTranscription.transcribe(
            samples: Self.speechLike(seconds: 100),
            options: WhisperTranscription.decodingOptions(
                language: nil, translate: false, quality: .balanced, promptTokens: nil
            )
        ) { _, options in
            seen.append((options.language, options.detectLanguage))
            let text = seen.count == 1 ? " " : "namaste"
            return [TranscriptionResult(text: text, segments: [], language: "hi", timings: TranscriptionTimings())]
        }
        #expect(seen.count >= 4)
        #expect(seen[0].language == nil && seen[0].detects == true)
        #expect(seen[1].language == nil && seen[1].detects == true)
        for later in seen.dropFirst(2) {
            #expect(later.language == "hi")
            #expect(later.detects == false)
        }
    }

    /// A window that said nothing, or too little, does not decide it.
    @Test func onlyAWindowWithWordsDecidesTheLanguage() {
        let automatic = WhisperTranscription.decodingOptions(
            language: nil, translate: false, quality: .balanced, promptTokens: nil
        )
        let long = WhisperTranscription.minimumDetectionSamples
        let blank = [TranscriptionResult(text: " ", segments: [], language: "ja", timings: TranscriptionTimings())]
        #expect(WhisperTranscription.lockingDetectedLanguage(automatic, after: blank, windowSamples: long).language == nil)
        let short = WhisperTranscription.lockingDetectedLanguage(
            automatic, after: Self.said("hi there"), windowSamples: long - 1
        )
        #expect(short.language == nil)
        #expect(short.detectLanguage == true)
        #expect(WhisperTranscription.lockingDetectedLanguage(
            automatic, after: Self.said("hi there"), windowSamples: long
        ).language == "en")
    }

    /// A window that returned only a marker heard no speech, and must not
    /// decide the language the dictation is decoded in.
    @Test func aMarkerOnlyWindowDoesNotDecideTheLanguage() {
        let automatic = WhisperTranscription.decodingOptions(
            language: nil, translate: false, quality: .balanced, promptTokens: nil
        )
        let marker = [TranscriptionResult(
            text: "[BLANK_AUDIO]", segments: [], language: "ja", timings: TranscriptionTimings()
        )]
        let after = WhisperTranscription.lockingDetectedLanguage(
            automatic, after: marker, windowSamples: WhisperTranscription.minimumDetectionSamples
        )
        #expect(after.language == nil)
        #expect(after.detectLanguage == true)
    }

    /// The reported language is the one that decided, not whatever a blank
    /// first window happened to detect.
    @Test func theReportedLanguageIsTheOneThatDecided() {
        func result(_ text: String, _ language: String) -> TranscriptionResult {
            TranscriptionResult(text: text, segments: [], language: language, timings: TranscriptionTimings())
        }
        #expect(WhisperTranscription.reportedLanguage(
            [result(" ", "en"), result("[BLANK_AUDIO]", "ja"), result("namaste", "hi"), result("ji", "hi")]
        ) == "hi")
        #expect(WhisperTranscription.reportedLanguage([result(" ", "en")]) == "en")
        #expect(WhisperTranscription.reportedLanguage([]) == "")
    }

    /// A window that did not lock the language — too short, or no detection
    /// to go on — must not label the recording with its own guess: once a
    /// later window locks, every result carries the language the rest was
    /// decoded in.
    @Test func everyResultCarriesTheLockedLanguage() async throws {
        var window = 0
        let results = try await WhisperTranscription.transcribe(
            samples: Self.speechLike(seconds: 70),
            options: WhisperTranscription.decodingOptions(
                language: nil, translate: false, quality: .balanced, promptTokens: nil
            )
        ) { _, options in
            window += 1
            let guess = options.language ?? (window == 1 ? "" : "hi")
            return [TranscriptionResult(text: "words", segments: [], language: guess, timings: TranscriptionTimings())]
        }
        #expect(results.count >= 3)
        #expect(results.allSatisfy { $0.language == "hi" })
        #expect(WhisperTranscription.reportedLanguage(results) == "hi")
    }

    /// A language the user chose is never replaced by a detected one.
    @Test func aChosenLanguageIsLeftAlone() {
        let german = WhisperTranscription.decodingOptions(
            language: "de", translate: false, quality: .balanced, promptTokens: nil
        )
        let after = WhisperTranscription.lockingDetectedLanguage(
            german, after: Self.said("hello"), windowSamples: WhisperTranscription.minimumDetectionSamples
        )
        #expect(after.language == "de")
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

    /// Thirty seconds that never falls quiet, so the chunker cuts exactly at
    /// the limit and leaves `tail` as a window of its own.
    private static func withShortTail(_ tail: [Float]) -> [Float] {
        [Float](repeating: 0.2, count: 30 * 16_000) + tail
    }

    /// A last word shorter than half a second: too few frames to measure a
    /// quiet stretch in, so it is measured against the recording's own.
    @Test func shortFinalWordThatDecodesToNothingIsReported() async throws {
        let lastWord = (0..<6_400).map { sin(Float($0) * 0.2) * 0.9 }
        var reported: [WhisperTranscription.EmptyWindow] = []
        var window = 0
        _ = try await WhisperTranscription.transcribe(
            samples: Self.withShortTail(lastWord),
            options: DecodingOptions(),
            emptyWindow: { reported.append($0) }
        ) { _, _ in
            defer { window += 1 }
            return window == 0 ? Self.said("everything but the last word") : []
        }
        #expect(reported.count == 1)
        #expect(reported.first?.index == 1)
        #expect(reported.first?.count == 2)
        #expect((reported.first?.milliseconds ?? .max) < 500)
    }

    /// The same short window holding nothing that stands out from the rest of
    /// the recording.
    @Test func shortFinalSteadySoundIsNotReported() async throws {
        var reported = 0
        var windows = 0
        _ = try await WhisperTranscription.transcribe(
            samples: Self.withShortTail([Float](repeating: 0.2, count: 6_400)),
            options: DecodingOptions(),
            emptyWindow: { _ in reported += 1 }
        ) { _, _ in
            windows += 1
            return windows == 1 ? Self.said("all of it") : []
        }
        #expect(windows == 2)
        #expect(reported == 0)
    }

    @Test func aTailTooShortForAWordIsNeverSpeech() {
        let recording = Self.unbrokenSpeech(seconds: 5)
        let blip = (0..<1_600).map { sin(Float($0) * 0.2) * 0.3 }
        #expect(!WhisperTranscription.soundsLikeSpeech(blip, in: recording + blip))
        #expect(!WhisperTranscription.soundsLikeSpeech(Array(repeating: 0.3, count: 6_400)))
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

    // MARK: - Retries keep the best attempt

    private static func attempt(
        _ text: String,
        logProb: Float,
        compression: Float = 1.5,
        noSpeech: Float = 0.01,
        language: String = "en"
    ) -> [TranscriptionResult] {
        let segment = TranscriptionSegment(
            text: text,
            tokens: Array(repeating: 1, count: 10),
            avgLogprob: logProb,
            compressionRatio: compression,
            noSpeechProb: noSpeech
        )
        return [TranscriptionResult(text: text, segments: [segment], language: language, timings: TranscriptionTimings())]
    }

    private static let options = WhisperTranscription.decodingOptions(
        language: nil, translate: false, quality: .balanced, promptTokens: nil
    )

    /// WhisperKit's own fallback returned its last attempt whatever it said.
    @Test func aWorseRetryNeverReplacesTheFirstAnswer() async throws {
        var calls = 0
        let kept = try await WhisperTranscription.decodeBest([0], options: Self.options, retries: 1) { _, _ in
            calls += 1
            return calls == 1
                ? Self.attempt("the model's best guess", logProb: -1.2)
                : Self.attempt("a random sample", logProb: -1.9)
        }
        #expect(calls == 2)
        #expect(kept.first?.text == "the model's best guess")
    }

    @Test func aRepetitionLoopIsReplacedByAnAnswerThatIsNotOne() async throws {
        var calls = 0
        let kept = try await WhisperTranscription.decodeBest([0], options: Self.options, retries: 2) { _, _ in
            calls += 1
            return calls == 1
                ? Self.attempt("so so so so so so so so", logProb: -0.1, compression: 4)
                : Self.attempt("so I said", logProb: -0.6)
        }
        // The second answer was good enough to stop at.
        #expect(calls == 2)
        #expect(kept.first?.text == "so I said")
    }

    @Test func anEmptyRetryNeverReplacesWords() async throws {
        var calls = 0
        let kept = try await WhisperTranscription.decodeBest([0], options: Self.options, retries: 1) { _, _ in
            calls += 1
            return calls == 1 ? Self.attempt("hard to hear", logProb: -1.4) : []
        }
        #expect(kept.first?.text == "hard to hear")
    }

    /// A retry samples, and used to detect the language again with the same
    /// sampler — a Hindi window could come back as Urdu.
    @Test func aRetryKeepsTheLanguageTheFirstAttemptHeard() async throws {
        var retries: [DecodingOptions] = []
        _ = try await WhisperTranscription.decodeBest([0], options: Self.options, retries: 1) { _, options in
            if options.temperature > 0 { retries.append(options) }
            return Self.attempt("namaste", logProb: -1.5, language: "hi")
        }
        #expect(retries.count == 1)
        #expect(retries.first?.language == "hi")
        #expect(retries.first?.detectLanguage == false)
        #expect(retries.first?.temperature == WhisperTranscription.retryTemperature)
    }

    @Test func aCleanOrSilentWindowIsNeverRetried() async throws {
        for first in [
            Self.attempt("all good", logProb: -0.3),
            Self.attempt("thank you", logProb: -1.6, noSpeech: 0.9),
            [],
        ] {
            var calls = 0
            _ = try await WhisperTranscription.decodeBest([0], options: Self.options, retries: 2) { _, _ in
                calls += 1
                return first
            }
            #expect(calls == 1)
        }
    }

    @Test func fastNeverRetries() async throws {
        var calls = 0
        _ = try await WhisperTranscription.decodeBest([0], options: Self.options, retries: 0) { _, _ in
            calls += 1
            return Self.attempt("loop loop loop loop", logProb: -0.1, compression: 5)
        }
        #expect(calls == 1)
    }

    // MARK: - A bounded token budget

    @Test func aWindowMayNotRunToTheWholeContextOnAFewSecondsOfAudio() {
        #expect(WhisperTranscription.sampleLength(forWindowSamples: 16_000) == 64)
        #expect(WhisperTranscription.sampleLength(forWindowSamples: 3 * 16_000) == 90)
        #expect(WhisperTranscription.sampleLength(forWindowSamples: 30 * 16_000) == Constants.maxTokenContext)
    }

    @Test func theBudgetReachesTheDecoder() async throws {
        var budgets: [Int] = []
        _ = try await WhisperTranscription.transcribe(
            samples: [Float](repeating: 0.2, count: 3 * 16_000),
            options: DecodingOptions()
        ) { _, options in
            budgets.append(options.sampleLength)
            return []
        }
        #expect(budgets == [90])
    }

    // MARK: - Windows decoded early

    @Test func aWindowDecodedEarlyIsNotDecodedAgain() async throws {
        let cache = WhisperWindowCache()
        let samples = Self.speechLike(seconds: 8)
        var decodes = 0
        let early = try await WhisperTranscription.transcribe(
            samples: samples, options: DecodingOptions(), cache: cache
        ) { _, _ in
            decodes += 1
            return Self.said("early")
        }
        let atFinish = try await WhisperTranscription.transcribe(
            samples: samples, options: DecodingOptions(), cache: cache
        ) { _, _ in
            decodes += 1
            return Self.said("again")
        }
        #expect(decodes == 1)
        #expect(early.first?.text == "early")
        #expect(atFinish.first?.text == "early")
        #expect(cache.hits == 1)
    }

    /// A louder passage later in the dictation changes the gain, and the same
    /// stretch levelled differently is different audio.
    @Test func aWindowLevelledDifferentlyIsDecodedAgain() async throws {
        let cache = WhisperWindowCache()
        let samples = Self.speechLike(seconds: 8)
        var decodes = 0
        for gain: Float in [2, 3] {
            _ = try await WhisperTranscription.transcribe(
                samples: samples,
                options: DecodingOptions(),
                cache: cache,
                levelling: WhisperWindowCache.Levelling(gain: gain, offset: 0)
            ) { _, _ in
                decodes += 1
                return Self.said("words")
            }
        }
        #expect(decodes == 2)
        #expect(cache.hits == 0)
    }

    /// Only the windows that changed are decoded: a dictation that ran on past
    /// its early decode keeps its finished first window.
    @Test func aLongerRecordingReusesOnlyTheWindowsItShares() async throws {
        let cache = WhisperWindowCache()
        let first = Self.speechLike(seconds: 40)
        let longer = first + Self.speechLike(seconds: 10)
        var decoded: [Int] = []
        _ = try await WhisperTranscription.transcribe(samples: first, options: DecodingOptions(), cache: cache) { window, _ in
            decoded.append(window.count)
            return Self.said("words")
        }
        let earlyWindows = decoded.count
        var windowsOfLonger = 0
        _ = try await WhisperTranscription.transcribe(samples: longer, options: DecodingOptions()) { _, _ in
            windowsOfLonger += 1
            return Self.said("words")
        }
        decoded = []
        _ = try await WhisperTranscription.transcribe(samples: longer, options: DecodingOptions(), cache: cache) { window, _ in
            decoded.append(window.count)
            return Self.said("words")
        }
        #expect(earlyWindows == 2)
        // The first window is the same thirty seconds either way; the second
        // grew, so it is decoded again.
        #expect(cache.hits == 1)
        #expect(decoded.count == windowsOfLonger - 1)
    }
}
