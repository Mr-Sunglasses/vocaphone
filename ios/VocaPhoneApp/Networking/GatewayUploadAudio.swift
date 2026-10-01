import AVFAudio
import Foundation

/// A disposable wire representation. The session's WAV remains authoritative
/// for retry and on-device decoding; only this temporary copy is lossy.
struct GatewayUploadAudio: Sendable {
    let fileURL: URL
    private let temporaryDirectory: URL?

    func removeTemporaryFile() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    /// Encoding and file I/O stay off the main actor. Cancellation propagates
    /// into the bounded read/write loop and removes any partially encoded file.
    static func prepare(
        sourceURL: URL,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) async throws -> Self {
        let encoding = Task.detached(priority: .userInitiated) {
            try encode(sourceURL: sourceURL, temporaryRoot: temporaryRoot)
        }
        return try await withTaskCancellationHandler {
            let prepared = try await encoding.value
            do {
                try Task.checkCancellation()
                return prepared
            } catch {
                prepared.removeTemporaryFile()
                throw error
            }
        } onCancel: {
            encoding.cancel()
        }
    }

    private static func encode(sourceURL: URL, temporaryRoot: URL) throws -> Self {
        try Task.checkCancellation()
        let original = Self(fileURL: sourceURL, temporaryDirectory: nil)
        guard sourceURL.pathExtension.lowercased() == "wav" else { return original }

        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("upload.m4a")
        do {
            let input = try AVAudioFile(forReading: sourceURL)
            // Current capture is already mono 16 kHz. Leave older or unfamiliar
            // formats intact rather than introducing another resampler here.
            guard input.processingFormat.sampleRate == CaptureFormat.sampleRate,
                  input.processingFormat.channelCount == 1 else { return original }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeAAC(input: input, destination: destination)
            try Task.checkCancellation()
            let sourceSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let encodedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            // Container overhead can make a very short M4A larger than its WAV.
            guard encodedSize > 0, encodedSize < sourceSize else {
                try? FileManager.default.removeItem(at: directory)
                return original
            }
            return Self(fileURL: destination, temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            try Task.checkCancellation()
            // A codec or disk failure must not make a recoverable WAV unusable.
            return original
        }
    }

    private static func writeAAC(input: AVAudioFile, destination: URL) throws {
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: CaptureFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ],
            commonFormat: input.processingFormat.commonFormat,
            interleaved: input.processingFormat.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat, frameCapacity: 4_096
        ) else { throw CocoaError(.fileReadUnknown) }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            try output.write(from: buffer)
        }
        // Leaving this scope closes the encoder and writes its final packets
        // and container metadata before the caller measures or uploads it.
    }
}
