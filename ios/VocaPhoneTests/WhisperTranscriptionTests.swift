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
