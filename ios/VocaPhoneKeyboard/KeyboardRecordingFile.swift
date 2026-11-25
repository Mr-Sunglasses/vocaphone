import AVFAudio
import Foundation

/// A keyboard recording, written as the app writes its own: 16 kHz mono
/// 16-bit WAV in the App Group's `pending-audio` directory, named after the
/// session. Kept there rather than in the extension's temporary directory so
/// the session's Retry can still find it after iOS ends this keyboard, and so
/// the app's orphaned-audio sweep cleans up after a keyboard that never came
/// back. Deleted as soon as a transcript exists.
@MainActor
final class KeyboardRecordingFile {
    let url: URL
    /// Nil once closed: leaving scope is what writes the WAV header's sizes
    /// and the last samples, so the file is never read while this is set.
    private var file: AVAudioFile?
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private(set) var frames: AVAudioFramePosition = 0
    private(set) var peak: Float = 0

    nonisolated static func directory() throws -> URL {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        ) else { throw SharedStoreError.appGroupUnavailable }
        let directory = group.appendingPathComponent("pending-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static func url(for reference: String) -> URL? {
        guard !reference.contains("/") else { return nil }
        return try? directory().appendingPathComponent(reference)
    }

    init(sessionID: UUID, inputSampleRate: Double) throws {
        url = try Self.directory().appendingPathComponent("\(sessionID.uuidString).wav")
        let sampleRate = CaptureFormat.sampleRate
        guard let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false
        ), let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: input, to: output)
        else { throw CocoaError(.featureUnsupported) }
        inputFormat = input
        outputFormat = output
        self.converter = converter
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Little-endian Int16 samples at the input rate. Returns the same audio
    /// as 16 kHz mono Float32 — the chunk format the app streams to the
    /// gateway — or nil when nothing was converted.
    @discardableResult
    func append(int16 data: Data) -> Data? {
        let count = data.count / 2
        guard count > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count))
        else { return nil }
        input.frameLength = AVAudioFrameCount(count)
        let target = input.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                let value = Float(Int16(littleEndian: samples[index])) / 32_768
                target[index] = value
                peak = max(peak, abs(value))
            }
        }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(count) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        // After a failed write the file stops, as the app's does: a recording
        // with a hole in the middle is worse than one that ends early and
        // says so. The stream, which does not need the file, carries on.
        if let file, !writeFailed {
            do {
                try file.write(from: output)
                frames += AVAudioFramePosition(output.frameLength)
            } catch {
                writeFailed = true
            }
        }
        return Data(bytes: output.floatChannelData![0], count: Int(output.frameLength) * 4)
    }

    /// A write to the WAV failed (a full disk, most often), so it holds only
    /// part of the recording and cannot stand in for a failed stream.
    private(set) var writeFailed = false

    var seconds: Double { Double(frames) / CaptureFormat.sampleRate }

    /// Finishes the WAV so it can be read or sent. Later appends still
    /// convert for the stream but write nothing.
    func close() {
        file = nil
    }
}
