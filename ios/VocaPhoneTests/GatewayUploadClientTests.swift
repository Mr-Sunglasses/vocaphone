import AVFAudio
import Foundation
import Testing

struct GatewayUploadClientTests {
    @Test func clientUploadsDecodableAACAndRemovesItsTemporaryCopy() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeRecording(in: directory)
        let original = try Data(contentsOf: source)
        let scratch = directory.appendingPathComponent("scratch")
        let server = try GatewayRecordingUploadTests.UploadServer()
        let port = try await server.start()
        defer { server.cancel() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let client = makeClient(port: port, session: session, scratch: scratch)
        let result = try await client.uploadAudio(sessionID: UUID(), fileURL: source)
        #expect(result.state == "uploaded")
        let headers = server.headers.withLock { $0.lowercased() }
        #expect(headers.hasPrefix("put /v1/sessions/"))
        #expect(headers.contains("content-type: audio/mp4"))
        #expect(headers.contains("authorization: bearer " + String(repeating: "x", count: 32)))
        let body = server.received.withLock { $0 }
        // M4A has fixed container overhead, which dominates this one-second clip.
        #expect(body.count < original.count)
        #expect(String(decoding: body.dropFirst(4).prefix(4), as: UTF8.self) == "ftyp")
        let received = directory.appendingPathComponent("received.m4a")
        try body.write(to: received)
        let decoded = try AVAudioFile(forReading: received)
        #expect(decoded.processingFormat.sampleRate == 16_000)
        #expect(abs(decoded.length - 16_000) < 1_024)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func failedUploadKeepsTheWAVAndRemovesItsTemporaryCopy() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeRecording(in: directory)
        let original = try Data(contentsOf: source)
        let scratch = directory.appendingPathComponent("scratch")
        let server = try GatewayRecordingUploadTests.UploadServer(reject: true)
        let port = try await server.start()
        defer { server.cancel() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let client = makeClient(port: port, session: session, scratch: scratch)
        await #expect(throws: GatewayError.self) {
            try await client.uploadAudio(sessionID: UUID(), fileURL: source)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func cancellationWhileAwaitingTheResponseRemovesTheUploadCopy() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeRecording(in: directory)
        let original = try Data(contentsOf: source)
        let scratch = directory.appendingPathComponent("scratch")
        let server = try GatewayRecordingUploadTests.UploadServer(holdResponse: true)
        let port = try await server.start()
        defer { server.cancel() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let client = makeClient(port: port, session: session, scratch: scratch)
        let uploading = Task { try await client.uploadAudio(sessionID: UUID(), fileURL: source) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.finished.withLock({ $0 }) {
            guard ContinuousClock.now < deadline else {
                uploading.cancel()
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: scratch.path)).isEmpty)
        uploading.cancel()
        do {
            _ = try await uploading.value
            Issue.record("A cancelled upload returned success")
        } catch {
            #expect((error as? URLError)?.code == .cancelled || error is CancellationError)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    private func makeClient(port: UInt16, session: URLSession, scratch: URL) -> GatewayClient {
        GatewayClient(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            token: String(repeating: "x", count: 32), session: session,
            uploadTemporaryRoot: scratch
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRecording(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("capture.wav")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<16_000 { samples[index] = sin(Float(index) * 0.1) * 0.4 }
        let file = try AVAudioFile(
            forWriting: url, settings: AudioCapturePipeline.fileSettings(),
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer)
        return url
    }
}
