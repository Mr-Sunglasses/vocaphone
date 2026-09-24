import Foundation
import WhisperKit

/// Decode one window at a time and propagate every window's error. WhisperKit
/// WhisperKit's built-in VAD path runs windows concurrently on iOS and drops
/// failed chunks when collecting results, potentially returning partial success.
@MainActor
enum WhisperTranscription {
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
        // Main-actor closures, like this type: the engine is not Sendable and
        // never leaves the actor that loaded it.
        load: @MainActor () async throws -> Engine,
        options: @MainActor (Engine) -> DecodingOptions,
        discard: @MainActor (Error) -> Void,
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
        return try await transcribe(samples: samples, options: options(engine!)) { window, windowOptions in
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

    static func transcribe(
        samples: [Float],
        options: DecodingOptions,
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
        var results: [TranscriptionResult] = []
        for chunk in chunks {
            try Task.checkCancellation()
            var samples = chunk.audioSamples
            // Whisper's seek loop skips clips shorter than windowClipTime.
            // Pad an audible short final window so its last word is decoded.
            let minimumSamples = Int((windowOptions.windowClipTime + 0.1) * Float(WhisperKit.sampleRate))
            if samples.count < minimumSamples {
                samples += [Float](repeating: 0, count: minimumSamples - samples.count)
            }
            let decoded = try await decode(samples, windowOptions)
            try Task.checkCancellation()
            results.append(contentsOf: decoded)
        }
        return results
    }
}
