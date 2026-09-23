import Foundation
import WhisperKit

/// Decode one window at a time and propagate every window's error. WhisperKit
/// 0.18's built-in VAD path runs four windows concurrently on iOS and drops
/// failed chunks when collecting results, potentially returning partial success.
@MainActor
enum WhisperTranscription {
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
