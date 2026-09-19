import Testing
import WhisperKit

@MainActor
struct WhisperTranscriptionTests {
    private enum Failure: Error { case decoder }

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
}
