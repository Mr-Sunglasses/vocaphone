import AVFAudio
import Testing

struct AudioCaptureTests {
    @Test func ringBufferRoundTripsAcrossTheWrapPoint() {
        let ring = PCMRingBuffer(capacity: 8)
        var output = [Float](repeating: 0, count: 8)

        let first: [Float] = [1, 2, 3, 4, 5]
        #expect(first.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 5) })
        var read = output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, maximum: 8)
        }
        #expect(read == 5)
        #expect(Array(output.prefix(5)) == first)

        // The next write starts at index five and wraps back to zero.
        let second: [Float] = [6, 7, 8, 9, 10]
        #expect(second.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 5) })
        read = output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, maximum: 8)
        }
        #expect(read == 5)
        #expect(Array(output.prefix(5)) == second)
    }

    /// The render thread must never block or overwrite unread audio; it drops
    /// and reports instead, which the caller turns into a file upload.
    @Test func ringBufferReportsOverflowRatherThanOverwriting() {
        let ring = PCMRingBuffer(capacity: 4)
        let tooMuch: [Float] = [1, 2, 3, 4, 5]

        #expect(!tooMuch.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 5) })
        #expect(ring.overflowCount == 1)

        let fits: [Float] = [1, 2, 3, 4]
        #expect(fits.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 4) })
    }

    @Test func ringBufferReadsNothingWhenEmpty() {
        let ring = PCMRingBuffer(capacity: 16)
        var output = [Float](repeating: 0, count: 4)
        let read = output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, maximum: 4)
        }
        #expect(read == 0)
    }

    /// One second of 48 kHz input must land as one second of 16 kHz, 16-bit
    /// audio on disk and as float32 chunks on the wire.
    @Test func pipelineConvertsToTheTranscriptionFormat() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("capture.wav")

        let sourceRate: Double = 48_000
        let ring = PCMRingBuffer(capacity: Int(sourceRate * 2))
        let pipeline = try #require(
            AudioCapturePipeline(sourceSampleRate: sourceRate, ring: ring)
        )

        let collected = Collector()
        try pipeline.start(writingTo: output) { data in
            collected.append(data)
            return true
        }

        let sampleCount = Int(sourceRate)
        var tone = [Float](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            tone[index] = sin(Float(index) * 0.05) * 0.5
        }
        tone.withUnsafeBufferPointer { buffer in
            #expect(ring.write(buffer.baseAddress!, count: sampleCount))
        }
        pipeline.finish()

        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.sampleRate == CaptureFormat.sampleRate)
        #expect(file.fileFormat.channelCount == 1)
        // Resampling loses a few frames to filter delay; a second of audio
        // should still be within a hair of 16,000 frames.
        #expect(abs(file.length - 16_000) < 400)

        let emittedSamples = collected.totalBytes / MemoryLayout<Float>.size
        #expect(abs(emittedSamples - 16_000) < 400)
        #expect(pipeline.droppedChunkCount == 0)
        #expect(pipeline.meterLevel > 0)
        #expect(pipeline.peakLevel > CaptureFormat.silenceThreshold)
    }

    /// Digital silence is what iOS hands an app whose microphone another app
    /// has taken. It has to be told apart from a quiet room, because one is
    /// worth explaining to the user and the other is just a short recording.
    @Test func pipelineTellsSilenceApartFromAQuietRoom() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceRate: Double = 48_000
        func peak(of samples: [Float], named name: String) throws -> Float {
            let ring = PCMRingBuffer(capacity: Int(sourceRate * 2))
            let pipeline = try #require(
                AudioCapturePipeline(sourceSampleRate: sourceRate, ring: ring)
            )
            try pipeline.start(writingTo: directory.appendingPathComponent(name)) { _ in true }
            samples.withUnsafeBufferPointer {
                #expect(ring.write($0.baseAddress!, count: samples.count))
            }
            pipeline.finish()
            return pipeline.peakLevel
        }

        let count = Int(sourceRate)
        let silenced = try peak(of: [Float](repeating: 0, count: count), named: "silence.wav")
        #expect(silenced <= CaptureFormat.silenceThreshold)

        // A murmur a hundred times quieter than a normal voice is still speech.
        var murmur = [Float](repeating: 0, count: count)
        for index in 0..<count {
            murmur[index] = sin(Float(index) * 0.05) * 0.01
        }
        #expect(try peak(of: murmur, named: "murmur.wav") > CaptureFormat.silenceThreshold)
    }

    @Test func pipelineCountsChunksTheTransportRefuses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceRate: Double = 48_000
        let ring = PCMRingBuffer(capacity: Int(sourceRate * 2))
        let pipeline = try #require(
            AudioCapturePipeline(sourceSampleRate: sourceRate, ring: ring)
        )
        try pipeline.start(writingTo: directory.appendingPathComponent("refused.wav")) { _ in
            false
        }

        let tone = [Float](repeating: 0.25, count: Int(sourceRate))
        tone.withUnsafeBufferPointer { buffer in
            #expect(ring.write(buffer.baseAddress!, count: tone.count))
        }
        pipeline.finish()

        #expect(pipeline.droppedChunkCount > 0)
    }

    /// The emit callback runs on the pipeline's queue, so the test's tally
    /// needs its own synchronisation.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0

        func append(_ data: Data) {
            lock.withLock { bytes += data.count }
        }

        var totalBytes: Int { lock.withLock { bytes } }
    }
}
