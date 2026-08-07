import AVFAudio
import Accelerate
import Foundation
import os

/// Speech models resample to 16 kHz internally, so converting once at capture
/// removes a six-fold overhead from every byte that follows: the file on disk,
/// the WebSocket payload, and the fallback upload.
enum CaptureFormat {
    static let sampleRate: Double = 16_000
    /// Roughly 100 ms of audio per chunk. Small enough to keep streaming
    /// latency low, large enough to avoid a WebSocket frame every drain tick.
    static let chunkSampleCount = 1_600
}

/// Single-producer, single-consumer float ring buffer with preallocated
/// storage. The audio render thread may only copy bytes and move a cursor: no
/// allocation, no file access, and no lock held longer than a word write.
final class PCMRingBuffer: @unchecked Sendable {
    private struct Cursor: Sendable {
        var written = 0
        var read = 0
    }

    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let cursor = OSAllocatedUnfairLock(initialState: Cursor())
    private let overflows = OSAllocatedUnfairLock(initialState: 0)

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    var overflowCount: Int { overflows.withLock { $0 } }

    func reset() {
        cursor.withLock { $0 = Cursor() }
        overflows.withLock { $0 = 0 }
    }

    /// Called from the realtime render thread.
    @discardableResult
    func write(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return true }
        let (written, read) = cursor.withLock { ($0.written, $0.read) }
        guard written - read + count <= capacity else {
            overflows.withLock { $0 += 1 }
            return false
        }
        let offset = written % capacity
        let contiguous = min(count, capacity - offset)
        storage.advanced(by: offset).update(from: samples, count: contiguous)
        if contiguous < count {
            storage.update(from: samples.advanced(by: contiguous), count: count - contiguous)
        }
        cursor.withLock { $0.written = written + count }
        return true
    }

    /// Called from the consumer queue.
    func read(into destination: UnsafeMutablePointer<Float>, maximum: Int) -> Int {
        let (written, read) = cursor.withLock { ($0.written, $0.read) }
        let available = min(written - read, maximum)
        guard available > 0 else { return 0 }
        let offset = read % capacity
        let contiguous = min(available, capacity - offset)
        destination.update(from: storage.advanced(by: offset), count: contiguous)
        if contiguous < available {
            destination.advanced(by: contiguous)
                .update(from: storage, count: available - contiguous)
        }
        cursor.withLock { $0.read = read + available }
        return available
    }
}

/// Drains the ring buffer off the render thread, converts to the transcription
/// format, writes the file, and hands finished chunks to the streaming bridge.
/// Everything expensive lives here so the tap itself stays realtime-safe.
final class AudioCapturePipeline: @unchecked Sendable {
    private let ring: PCMRingBuffer
    private let queue = DispatchQueue(label: "com.vocahq.vocaphone.capture", qos: .userInitiated)
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int

    private var timer: DispatchSourceTimer?
    private var file: AVAudioFile?
    private var carry: [Float] = []
    private let meter = OSAllocatedUnfairLock(initialState: Float(0))
    private let dropped = OSAllocatedUnfairLock(initialState: 0)
    private var emit: ((Data) -> Bool)?

    /// Chunks the transport refused to buffer. Any loss makes the stream
    /// untrustworthy, so the caller falls back to uploading the intact file.
    var droppedChunkCount: Int { dropped.withLock { $0 } }
    var meterLevel: Float { meter.withLock { $0 } }

    init?(sourceSampleRate: Double, ring: PCMRingBuffer) {
        guard let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ),
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: CaptureFormat.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: source, to: target)
        else { return nil }

        // One drain tick's worth of audio, sized once so the hot path never
        // allocates a buffer.
        let inputCapacity = AVAudioFrameCount(sourceSampleRate * 0.25)
        let outputCapacity = AVAudioFrameCount(
            Double(inputCapacity) * CaptureFormat.sampleRate / sourceSampleRate
        ) + 1_024
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inputCapacity),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity)
        else { return nil }

        self.ring = ring
        self.converter = converter
        sourceFormat = source
        targetFormat = target
        inputBuffer = input
        outputBuffer = output
        scratchCapacity = Int(inputCapacity)
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        scratch.deinitialize(count: scratchCapacity)
        scratch.deallocate()
    }

    /// The written file uses 16-bit samples while the processing format stays
    /// float; `AVAudioFile` narrows on write, halving the bytes on disk again.
    static func fileSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: CaptureFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    func start(writingTo url: URL, emit: @escaping (Data) -> Bool) throws {
        let handle = try AVAudioFile(
            forWriting: url,
            settings: Self.fileSettings(),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        queue.sync {
            self.file = handle
            self.emit = emit
            self.carry.removeAll(keepingCapacity: true)
            self.converter.reset()
        }
        dropped.withLock { $0 = 0 }
        meter.withLock { $0 = 0 }

        let source = DispatchSource.makeTimerSource(queue: queue)
        // A 25 ms cadence against a two-second ring leaves ample margin even if
        // the queue is briefly starved.
        source.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
        source.setEventHandler { [weak self] in self?.drain(flushingRemainder: false) }
        source.resume()
        timer = source
    }

    /// Drains whatever is still buffered, flushes a partial chunk, and closes
    /// the file so no tail of the recording is lost.
    func finish() {
        timer?.cancel()
        timer = nil
        queue.sync {
            self.drainLocked(flushingRemainder: true)
            self.file = nil
            self.emit = nil
        }
    }

    private func drain(flushingRemainder: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        drainLocked(flushingRemainder: flushingRemainder)
    }

    private func drainLocked(flushingRemainder: Bool) {
        while true {
            let count = ring.read(into: scratch, maximum: scratchCapacity)
            guard count > 0 else { break }
            process(sampleCount: count)
            guard count == scratchCapacity else { break }
        }
        if flushingRemainder, !carry.isEmpty {
            flushChunk(minimum: 1)
        }
    }

    private func process(sampleCount: Int) {
        guard let channel = inputBuffer.floatChannelData?[0] else { return }
        channel.update(from: scratch, count: sampleCount)
        inputBuffer.frameLength = AVAudioFrameCount(sampleCount)

        meter.withLock { $0 = Self.normalizedLevel(scratch, count: sampleCount) }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return self.inputBuffer
        }
        guard status != .error, outputBuffer.frameLength > 0 else { return }

        try? file?.write(from: outputBuffer)

        guard let converted = outputBuffer.floatChannelData?[0] else { return }
        carry.append(
            contentsOf: UnsafeBufferPointer(start: converted, count: Int(outputBuffer.frameLength))
        )
        flushChunk(minimum: CaptureFormat.chunkSampleCount)
    }

    private func flushChunk(minimum: Int) {
        guard let emit else {
            carry.removeAll(keepingCapacity: true)
            return
        }
        while carry.count >= minimum, !carry.isEmpty {
            let size = min(CaptureFormat.chunkSampleCount, carry.count)
            let slice = carry[0..<size]
            let data = slice.withUnsafeBufferPointer { pointer in
                Data(buffer: pointer)
            }
            carry.removeFirst(size)
            if !emit(data) {
                dropped.withLock { $0 += 1 }
            }
        }
    }

    private static func normalizedLevel(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return max(0, min(1, pow(10, decibels / 40)))
    }
}
