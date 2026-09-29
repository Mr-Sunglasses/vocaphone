import Foundation
import WhisperKit

/// Decode one window at a time and propagate every window's error. WhisperKit
/// WhisperKit's built-in VAD path runs windows concurrently on iOS and drops
/// failed chunks when collecting results, potentially returning partial success.
@MainActor
enum WhisperTranscription {
    /// How the app loads a downloaded model: from disk only, never the network.
    ///
    /// `load: false` with `prewarm: true` only compiles the model for the
    /// Neural Engine and leaves nothing resident — the last step of a download.
    static func engineConfig(
        model: String,
        folder: URL,
        tokenizerFolder: URL,
        prewarm: Bool,
        load: Bool = true
    ) -> WhisperKitConfig {
        WhisperKitConfig(
            model: model,
            modelFolder: folder.path,
            // WhisperKit searches this folder directly for tokenizer.json;
            // supplying it is what keeps model loading off the network.
            tokenizerFolder: tokenizerFolder,
            // The mel spectrogram defaults to the GPU, which iOS does not
            // let a backgrounded app use — and a dictation finished from
            // the keyboard runs with this app in the background. It is a
            // few milliseconds of work a window; the CPU is no loss.
            computeOptions: ModelComputeOptions(melCompute: .cpuOnly),
            verbose: false,
            prewarm: prewarm,
            load: load,
            download: false
        )
    }

    /// The options every on-device Whisper window is decoded with.
    ///
    /// `language` is nil for Automatic.
    static func decodingOptions(
        language: String?,
        translate: Bool,
        quality: TranscriptionQuality,
        promptTokens: [Int]?
    ) -> DecodingOptions {
        DecodingOptions(
            task: translate ? .translate : .transcribe,
            language: language,
            temperature: 0,
            // Never WhisperKit's own fallback: it keeps its *last* attempt,
            // not its best, so a hard window came back as whatever one sample
            // at a raised temperature happened to say. The window loop retries
            // instead, `quality.whisperRetryCount` times, and keeps the best.
            // See `decodeBest`.
            temperatureIncrementOnFallback: 0,
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            // WhisperKit derives this from `usePrefillPrompt`, so leaving it
            // unset with prefill on resolves it to false — and a nil language
            // then falls back to English rather than being detected. Automatic
            // has to ask for detection in so many words.
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            // Timestamp tokens are not shown, but Whisper needs to predict
            // them to stop cleanly instead of repeating into padded audio.
            withoutTimestamps: false,
            promptTokens: promptTokens,
            // WhisperKit defaults this off where Whisper itself defaults it
            // on. Leaving it off lets a window open on a blank token, which
            // is how a pause becomes a leading empty segment.
            suppressBlank: true,
            // Off, as it is in Whisper itself. Since WhisperKit 1.1.0 this check
            // scores the first predicted token, and with timestamps on that is
            // the opening `<|0.00|>`, whose probability is spread across every
            // timestamp. A window that opens on quiet speech falls under the
            // threshold, ends on the spot, fails the same way at every fallback
            // temperature, and comes back as empty text with no error — so the
            // first thirty seconds of a longer dictation vanished and only the
            // rest was typed. Before 1.1.0 the check scored a prompt token the
            // decoder then discarded, so it never fired on real speech. The
            // average-log-probability, compression and no-speech checks still
            // catch a window that decoded badly.
            firstTokenLogProbThreshold: nil,
            concurrentWorkerCount: 1
        )
    }

    /// Loads an engine and decodes every window on it, rebuilding the engine
    /// at most once for the whole recording.
    ///
    /// The rebuild is for the first dictation after the model was dropped: a
    /// cold Core ML load in a backgrounded app that fails, or hands back an
    /// engine whose next decode fails, where the very next attempt succeeds.
    /// A load failure spends it on a second load; a window failure spends it on
    /// a fresh engine that resumes at that window, so the windows already
    /// decoded and the load that produced them are never paid for twice — the
    /// background time this runs in is short. `discard` is where the caller
    /// throws the failed engine away. A failure after the rebuild is a real one
    /// and propagates, and cancellation is never retried.
    ///
    /// `options` are built once, against the first engine that loads. A rebuild
    /// reloads the same model, so its tokenizer — and any prompt tokens encoded
    /// with it — is the same.
    static func transcribe<Engine>(
        samples: [Float],
        retries: Int = 0,
        cache: WhisperWindowCache? = nil,
        levelling: WhisperWindowCache.Levelling = .unlevelled,
        // Main-actor closures, like this type: the engine is not Sendable and
        // never leaves the actor that loaded it.
        load: @MainActor () async throws -> Engine,
        options: @MainActor (Engine) -> DecodingOptions,
        discard: @MainActor (Error) -> Void,
        emptyWindow: ((EmptyWindow) -> Void)? = nil,
        decode: @MainActor (Engine, [Float], DecodingOptions) async throws -> [TranscriptionResult]
    ) async throws -> [TranscriptionResult] {
        var rebuilt = false
        func rebuild(after error: Error) async throws -> Engine {
            if rebuilt || error is CancellationError || Task.isCancelled { throw error }
            rebuilt = true
            discard(error)
            try Task.checkCancellation()
            return try await load()
        }

        func initialEngine() async throws -> Engine {
            do {
                return try await load()
            } catch {
                return try await rebuild(after: error)
            }
        }

        // Optional so the failed engine can be let go before its replacement is
        // built: two sets of weights resident at once is an out-of-memory kill.
        var engine: Engine? = try await initialEngine()
        return try await transcribe(
            samples: samples,
            options: options(engine!),
            retries: retries,
            cache: cache,
            levelling: levelling,
            emptyWindow: emptyWindow
        ) { window, windowOptions in
            let failure: Error
            do {
                return try await decode(engine!, window, windowOptions)
            } catch {
                failure = error
            }
            engine = nil
            engine = try await rebuild(after: failure)
            return try await decode(engine!, window, windowOptions)
        }
    }

    /// A window that held speech and came back without a word.
    ///
    /// Nothing about it fails: WhisperKit returns success with empty text, and
    /// the windows either side still produce theirs, so the transcript that
    /// reaches the field is simply missing a stretch. That is how a WhisperKit
    /// upgrade came to drop the first thirty seconds of long dictations with no
    /// error anywhere. This is reported so the diagnostics can say so.
    struct EmptyWindow: Equatable, Sendable {
        /// Zero-based, in recording order.
        let index: Int
        let count: Int
        let milliseconds: Int
    }

    /// `emptyWindow` is told about every window that sounds like speech and
    /// decoded to nothing. It changes nothing about the result.
    ///
    /// `cache` holds windows decoded earlier — during a pause in the same
    /// dictation — and a window found there is not decoded again. `levelling`
    /// is how `samples` were levelled, which is part of what makes two windows
    /// over the same stretch of a recording the same audio.
    static func transcribe(
        samples: [Float],
        options: DecodingOptions,
        retries: Int = 0,
        cache: WhisperWindowCache? = nil,
        levelling: WhisperWindowCache.Levelling = .unlevelled,
        emptyWindow: ((EmptyWindow) -> Void)? = nil,
        decode: ([Float], DecodingOptions) async throws -> [TranscriptionResult]
    ) async throws -> [TranscriptionResult] {
        // Keep a final sub-second tail too; it can contain the last spoken word.
        let chunks = try await VADAudioChunker(windowPadding: 0).chunkAll(
            audioArray: samples,
            maxChunkLength: 30 * WhisperKit.sampleRate,
            decodeOptions: options
        )
        var windowOptions = options
        windowOptions.clipTimestamps = []
        windowOptions.chunkingStrategy = nil
        windowOptions.concurrentWorkerCount = 1
        let recording = samples
        var results: [TranscriptionResult] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            var samples = chunk.audioSamples
            // Whisper's seek loop skips clips shorter than windowClipTime.
            // Pad an audible short final window so its last word is decoded.
            let minimumSamples = Int((windowOptions.windowClipTime + 0.1) * Float(WhisperKit.sampleRate))
            if samples.count < minimumSamples {
                samples += [Float](repeating: 0, count: minimumSamples - samples.count)
            }
            var bounded = windowOptions
            bounded.sampleLength = sampleLength(forWindowSamples: chunk.audioSamples.count)
            let key = WhisperWindowCache.Key(
                start: chunk.seekOffsetIndex,
                count: chunk.audioSamples.count,
                language: windowOptions.language,
                levelling: levelling
            )
            let decoded: [TranscriptionResult]
            if let cached = cache?.results(for: key) {
                decoded = cached
            } else {
                decoded = try await decodeBest(samples, options: bounded, retries: retries, decode: decode)
                cache?.store(decoded, for: key)
            }
            try Task.checkCancellation()
            windowOptions = Self.lockingDetectedLanguage(
                windowOptions,
                after: decoded,
                windowSamples: chunk.audioSamples.count
            )
            if let emptyWindow,
               decoded.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
               soundsLikeSpeech(chunk.audioSamples, in: recording)
            {
                emptyWindow(EmptyWindow(
                    index: index,
                    count: chunks.count,
                    milliseconds: chunk.audioSamples.count * 1_000 / WhisperKit.sampleRate
                ))
            }
            results.append(contentsOf: decoded)
        }
        // The language every window after the lock was decoded in is the
        // recording's language. Earlier windows each reported their own
        // guess — a blank one, a two-second fragment — and whichever came
        // first would otherwise label and punctuate the transcript.
        if options.language == nil, let locked = windowOptions.language {
            for result in results { result.language = locked }
        }
        return results
    }

    /// The temperature a retry samples at.
    ///
    /// 1.0 and nothing lower, because it is the only temperature whose scores
    /// can be compared with the first attempt's. WhisperKit reports each
    /// sampled token's log-probability from the softmax *after* dividing by the
    /// temperature, so a retry at 0.5 scores itself on a sharpened
    /// distribution and always looks more confident than it was. At 1.0 the
    /// two are measured on the same scale, and choosing between them means
    /// something.
    static let retryTemperature: Float = 1

    /// Decodes a window, and while the answer looks broken — a repetition
    /// loop, or text the model itself found unlikely — decodes it again up to
    /// `retries` times, keeping the best answer rather than the last.
    ///
    /// WhisperKit's own fallback keeps the last. On a hard window — an accent,
    /// a noisy room, Hindi with English in it — the first, greedy answer is
    /// usually the model's best guess, and one sample at a raised temperature
    /// replaced it whatever it said. It also re-detected the language with that
    /// sampler, so a retry could switch a Hindi window to Urdu. A retry here is
    /// pinned to the language the first attempt heard.
    static func decodeBest(
        _ samples: [Float],
        options: DecodingOptions,
        retries: Int,
        decode: ([Float], DecodingOptions) async throws -> [TranscriptionResult]
    ) async throws -> [TranscriptionResult] {
        var best = try await decode(samples, options)
        var bestQuality = WindowQuality(best, options: options)
        guard retries > 0, bestQuality.needsRetry else { return best }

        var retry = options
        retry.temperature = retryTemperature
        retry.temperatureFallbackCount = 0
        if retry.language == nil, let heard = best.first?.language, !heard.isEmpty {
            retry.language = heard
            retry.detectLanguage = false
        }
        for _ in 0..<retries {
            try Task.checkCancellation()
            let candidate = try await decode(samples, retry)
            let quality = WindowQuality(candidate, options: options)
            if bestQuality < quality {
                best = candidate
                bestQuality = quality
            }
            if !bestQuality.needsRetry { break }
        }
        return best
    }

    /// How good a decoded window looks, by the tests Whisper itself uses to
    /// decide a window failed, ordered so the better answer compares greater.
    struct WindowQuality: Comparable {
        let hasText: Bool
        let repetitive: Bool
        let averageLogProb: Float
        let needsRetry: Bool

        init(_ results: [TranscriptionResult], options: DecodingOptions) {
            let segments = results.flatMap(\.segments)
            let hasText = results.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let tokens = segments.reduce(0) { $0 + max(1, $1.tokens.count) }
            let averageLogProb = tokens == 0 ? 0 : segments.reduce(Float(0)) {
                $0 + $1.avgLogprob * Float(max(1, $1.tokens.count))
            } / Float(tokens)
            let repetitive = options.compressionRatioThreshold.map { threshold in
                segments.contains { $0.compressionRatio > threshold }
            } ?? false
            let unlikely = options.logProbThreshold.map { averageLogProb < $0 } ?? false
            self.hasText = hasText
            self.averageLogProb = averageLogProb
            self.repetitive = repetitive
            // Whisper's own exception: a window the model is sure holds no
            // speech is silence, and sampling it again only invites words.
            let silent = options.noSpeechThreshold.map { threshold in
                !segments.isEmpty && segments.allSatisfy { $0.noSpeechProb > threshold }
            } ?? false
            needsRetry = hasText && !silent && (repetitive || unlikely)
        }

        static func < (lhs: WindowQuality, rhs: WindowQuality) -> Bool {
            if lhs.hasText != rhs.hasText { return !lhs.hasText }
            if lhs.repetitive != rhs.repetitive { return lhs.repetitive }
            return lhs.averageLogProb < rhs.averageLogProb
        }
    }

    /// The most tokens one window may produce: thirty a second of its audio,
    /// and never fewer than 64.
    ///
    /// Whisper stops at its end-of-text token, so for a window that decodes
    /// cleanly this is never reached. It is for the one that does not: a
    /// repetition loop runs to the model's whole 224-token context, one decoder
    /// pass a token, before the compression check can call it — seconds, on a
    /// three-second dictation. Thirty a second is several times the densest
    /// speech in the most token-hungry script Whisper writes — Devanagari
    /// costs one token for every character or two.
    static func sampleLength(forWindowSamples samples: Int) -> Int {
        let seconds = Double(samples) / Double(WhisperKit.sampleRate)
        return min(Constants.maxTokenContext, max(64, Int((seconds * 30).rounded(.up))))
    }

    /// Automatic language, decided once per recording.
    ///
    /// Each thirty-second window used to detect its own language, so a
    /// dictation that mixes languages — Hindi with English words in it, say —
    /// could come back in Devanagari for one window and Latin script for the
    /// next, halfway through a sentence. whisper.cpp, which Android runs,
    /// detects once on the first window and keeps it, and this now does the
    /// same. The first window that produced words and carried at least
    /// ``minimumDetectionSamples`` decides: a blank window or a two-second
    /// fragment is a poor basis for the rest of the recording.
    static func lockingDetectedLanguage(
        _ options: DecodingOptions,
        after decoded: [TranscriptionResult],
        windowSamples: Int
    ) -> DecodingOptions {
        guard options.language == nil, options.detectLanguage == true,
              windowSamples >= minimumDetectionSamples,
              let detected = decoded.first(where: carriesSpeech)?.language,
              !detected.isEmpty
        else { return options }
        var locked = options
        locked.language = detected
        locked.detectLanguage = false
        return locked
    }

    /// Whether a result holds words rather than nothing or a marker.
    ///
    /// Judged after the sanitizer, the same way the finished transcript is:
    /// `[BLANK_AUDIO]` or `(music)` is text to the decoder but no speech to
    /// anyone, and a window of it must not decide what language the dictation
    /// is in.
    static func carriesSpeech(_ result: TranscriptionResult) -> Bool {
        !TranscriptSanitizer.clean(result.text).isEmpty
    }

    /// The language to report for a finished Automatic recording.
    ///
    /// Once a window has locked the language, ``transcribe(samples:options:emptyWindow:decode:)``
    /// has already set every result to it, so the first result answers. A
    /// recording where no window qualified reports the first window with
    /// words: a blank or marker-only first window detects something too, and
    /// reporting it would label the transcript in a language nobody spoke.
    static func reportedLanguage(_ results: [TranscriptionResult]) -> String {
        results.first(where: carriesSpeech)?.language ?? results.first?.language ?? ""
    }

    /// Five seconds of audio: enough speech for detection to mean something.
    static let minimumDetectionSamples = 5 * WhisperKit.sampleRate

    /// Whether a window carries at least half a second of sound well above its
    /// own quietest stretch.
    ///
    /// Movement, not level. Speech rises and falls with every syllable even
    /// when it never pauses: across the model tests' continuous speech the
    /// loudest tenth of 50 ms frames sits 12 to 16 times above the quietest.
    /// Hiss, hum and a fan hold their level, at 1.06 times whatever it is, and
    /// the app levels a quiet recording by up to eight times before decoding,
    /// so no absolute threshold can tell those apart from speech. Frames at
    /// two and a half times the quietest tenth can. Deliberately loose within
    /// that: a false "this was speech" costs one log line; a missed one hides
    /// a lost stretch of dictation.
    ///
    /// A final window under half a second — kept because it can hold the last
    /// word — has too few frames for a quiet stretch of its own. Given the
    /// whole `recording`, it is measured against the recording's quietest
    /// stretch instead, and half its frames standing out is enough.
    static func soundsLikeSpeech(_ samples: [Float], in recording: [Float]? = nil) -> Bool {
        let levels = frameLevels(samples)
        if levels.count >= minimumSpeechFrames {
            return loudFrameCount(levels, floor: quietestTenth(levels)) >= minimumSpeechFrames
        }
        // 150 ms: shorter than any word.
        guard let recording, levels.count >= 3 else { return false }
        let recordingLevels = frameLevels(recording)
        guard !recordingLevels.isEmpty else { return false }
        return loudFrameCount(levels, floor: quietestTenth(recordingLevels))
            >= max(3, (levels.count + 1) / 2)
    }

    /// Half a second of 50 ms frames.
    private static let minimumSpeechFrames = 10

    private static func frameLevels(_ samples: [Float]) -> [Float] {
        let frame = WhisperKit.sampleRate / 20
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            for sample in samples[start..<(start + frame)] { sum += sample * sample }
            levels.append((sum / Float(frame)).squareRoot())
            start += frame
        }
        return levels
    }

    private static func quietestTenth(_ levels: [Float]) -> Float {
        levels.sorted()[levels.count / 10]
    }

    private static func loudFrameCount(_ levels: [Float], floor: Float) -> Int {
        let threshold = max(0.01, floor * 2.5)
        return levels.filter { $0 >= threshold }.count
    }
}

/// Windows of one dictation already decoded, so a window decoded while the
/// speaker paused is not decoded again at Finish.
///
/// Keyed by everything that makes two windows the same decode: where the
/// window sits in the recording, how long it is, the language it was decoded
/// in, and how the recording was levelled — a louder sentence later in the
/// dictation changes the gain, and a window levelled differently is different
/// audio. Anything that does not match exactly is decoded again, so the cache
/// can make a dictation faster and never different.
@MainActor
final class WhisperWindowCache {
    struct Levelling: Hashable, Sendable {
        let gain: Float
        let offset: Float

        static let unlevelled = Levelling(gain: 1, offset: 0)

        init(gain: Float, offset: Float) {
            self.gain = gain
            self.offset = offset
        }

        init(_ levelled: SpeechAudioConditioning.Levelled) {
            self.init(gain: levelled.gain, offset: levelled.offset)
        }
    }

    struct Key: Hashable {
        let start: Int
        let count: Int
        let language: String?
        let levelling: Levelling
    }

    private var entries: [Key: [TranscriptionResult]] = [:]
    /// Windows answered from the cache rather than decoded.
    private(set) var hits = 0

    func results(for key: Key) -> [TranscriptionResult]? {
        guard let results = entries[key] else { return nil }
        hits += 1
        return results
    }

    func store(_ results: [TranscriptionResult], for key: Key) {
        entries[key] = results
    }
}
