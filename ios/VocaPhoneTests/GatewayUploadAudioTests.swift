import AVFAudio
import Foundation
import Testing

struct GatewayUploadAudioTests {
    @Test func compressedUploadDecodesThroughTheLastWordAndKeepsTheOriginal() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("capture.wav")
        try writeTone(to: source, seconds: 10)
        let original = try Data(contentsOf: source)
        let scratch = directory.appendingPathComponent("scratch")

        let prepared = try await GatewayUploadAudio.prepare(sourceURL: source, temporaryRoot: scratch)
        defer { prepared.removeTemporaryFile() }
        #expect(prepared.fileURL.pathExtension == "m4a")
        let compressed = try Data(contentsOf: prepared.fileURL)
        #expect(compressed.count < original.count / 4)
        #expect(try Data(contentsOf: source) == original)

        let decoded = try AVAudioFile(forReading: prepared.fileURL)
        #expect(decoded.processingFormat.sampleRate == 16_000)
        #expect(decoded.processingFormat.channelCount == 1)
        #expect(abs(decoded.length - 160_000) < 1_024)
        // AAC's delayed final packets must be flushed before upload. The final
        // quarter-second is a distinct tone after a silent pause.
        decoded.framePosition = decoded.length - 2_000
        let tail = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 2_000))
        try decoded.read(into: tail)
        let samples = try #require(tail.floatChannelData?[0])
        let energy = (0..<Int(tail.frameLength)).reduce(Float(0)) { $0 + samples[$1] * samples[$1] }
        #expect(energy / Float(tail.frameLength) > 0.01)

        prepared.removeTemporaryFile()
        #expect(!FileManager.default.fileExists(atPath: prepared.fileURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func containerOverheadDoesNotIncreaseATinyUpload() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tiny.wav")
        try writeTone(to: source, seconds: 0.01)
        let scratch = directory.appendingPathComponent("scratch")
        let prepared = try await GatewayUploadAudio.prepare(sourceURL: source, temporaryRoot: scratch)
        #expect(prepared.fileURL == source)
        prepared.removeTemporaryFile()
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func encodingFailureFallsBackWithoutDeletingRecoverableAudio() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("capture.wav")
        try writeTone(to: source, seconds: 1)
        let original = try Data(contentsOf: source)
        // A file where the temporary directory would be forces a write failure.
        let scratch = directory.appendingPathComponent("blocked")
        try Data([0]).write(to: scratch)
        let prepared = try await GatewayUploadAudio.prepare(sourceURL: source, temporaryRoot: scratch)
        #expect(prepared.fileURL == source)
        prepared.removeTemporaryFile()
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: scratch) == Data([0]))
    }

    @Test func alreadyCompressedRecordingsAreNotEncodedAgain() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("legacy.m4a")
        try Data([1, 2, 3]).write(to: source)
        let prepared = try await GatewayUploadAudio.prepare(sourceURL: source)
        #expect(prepared.fileURL == source)
        prepared.removeTemporaryFile()
        #expect(try Data(contentsOf: source) == Data([1, 2, 3]))
    }

    @Test func cancellationDoesNotBecomeAWAVFallbackOrLeaveAnEncodedCopy() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("capture.wav")
        try writeTone(to: source, seconds: 10)
        let scratch = directory.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GatewayUploadAudio.prepare(sourceURL: source, temporaryRoot: scratch)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func cancellingAfterEncodedPacketsExistRemovesThePartialM4A() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("capture.wav")
        try writeTone(to: source, seconds: 120)
        let original = try Data(contentsOf: source)
        let scratch = directory.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let encoding = Task {
            try await GatewayUploadAudio.prepare(sourceURL: source, temporaryRoot: scratch)
        }
        defer { encoding.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        var sawPackets = false
        while ContinuousClock.now < deadline {
            let directories = try FileManager.default.contentsOfDirectory(
                at: scratch, includingPropertiesForKeys: nil
            )
            if let partial = directories.first?.appendingPathComponent("upload.m4a"),
               let size = try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 4_096 {
                sawPackets = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(sawPackets)
        encoding.cancel()
        do {
            let prepared = try await encoding.value
            prepared.removeTemporaryFile()
            Issue.record("Encoding returned a file after cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeTone(to url: URL, seconds: Double) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let count = AVAudioFrameCount(seconds * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(count) {
            let time = Double(index) / 16_000
            let frequency = time > seconds - 0.25 ? 880.0 : 440.0
            samples[index] = time > seconds - 0.5 && time < seconds - 0.25
                ? 0 : Float(sin(time * 2 * .pi * frequency)) * 0.4
        }
        let file = try AVAudioFile(
            forWriting: url, settings: AudioCapturePipeline.fileSettings(),
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer)
    }
}
