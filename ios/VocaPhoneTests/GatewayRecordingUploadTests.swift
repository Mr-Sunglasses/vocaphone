import Foundation
import Network
import Testing
import os

struct GatewayRecordingUploadTests {
    @Test func audioReachesTheHTTPServerBeforeRecordingFinishes() async throws {
        let server = try UploadServer()
        let port = try await server.start()
        defer { server.cancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/audio")!)
        request.httpMethod = "PUT"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let upload = try GatewayRecordingUpload(request: request, configuration: .ephemeral)
        defer { upload.cancel() }
        try await upload.sendHeader()
        let samples = (0..<1_600).map { Float(sin(Double($0) * 0.1)) * 0.4 }
        let chunk = samples.withUnsafeBytes { Data($0) }
        try await upload.send(chunk)
        try await waitUntil { server.received.withLock { $0.count >= 3_244 } }
        #expect(server.received.withLock { $0 } == GatewayRecordingUpload.wavHeader + (try GatewayRecordingUpload.pcm16(chunk)))
        #expect(server.headers.withLock { $0.lowercased().contains("transfer-encoding: chunked") })
        #expect(server.headers.withLock { $0.lowercased().contains("authorization: bearer test-token") })
        #expect(!server.finished.withLock { $0 })
        let response = try await upload.finish()
        #expect(response.state == "uploaded")
        #expect(server.finished.withLock { $0 })
    }

    @Test func cancellingAnUnfinishedRequestUnblocksFinish() async throws {
        let server = try UploadServer()
        let port = try await server.start()
        defer { server.cancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/audio")!)
        request.httpMethod = "PUT"
        let upload = try GatewayRecordingUpload(request: request, configuration: .ephemeral)
        try await upload.sendHeader()
        try await waitUntil { server.received.withLock { $0.count >= 44 } }
        upload.cancel()
        await #expect(throws: CancellationError.self) { try await upload.finish() }
        await #expect(throws: CancellationError.self) { try await upload.send(Data(repeating: 0, count: 4)) }
    }

    @Test func pcmConversionClipsWithoutOverflowAndRejectsInvalidFrames() throws {
        let samples: [Float] = [-2, -1, 0, 0.5, 1, 2]
        let chunk = samples.withUnsafeBytes { Data($0) }
        #expect(try GatewayRecordingUpload.pcm16(chunk) == Data([0, 128, 0, 128, 0, 0, 0, 64, 255, 127, 255, 127]))
        #expect(throws: GatewayError.self) { try GatewayRecordingUpload.pcm16(Data([0])) }
        let invalid: [Float] = [.nan]
        #expect(throws: GatewayError.self) {
            try GatewayRecordingUpload.pcm16(invalid.withUnsafeBytes { Data($0) })
        }
    }

    @Test func anEarlyHTTPRejectionFailsTheLiveUpload() async throws {
        let server = try UploadServer(reject: true)
        let port = try await server.start()
        defer { server.cancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/audio")!)
        request.httpMethod = "PUT"
        let upload = try GatewayRecordingUpload(request: request, configuration: .ephemeral)
        defer { upload.cancel() }
        try await upload.sendHeader()
        await #expect(throws: GatewayError.self) { try await upload.finish() }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A real loopback HTTP/1.1 receiver: URLProtocol fakes do not exercise
    /// URLSession's bound body stream or whether bytes arrive before EOF.
    final class UploadServer: @unchecked Sendable {
        let received = OSAllocatedUnfairLock(initialState: Data())
        let headers = OSAllocatedUnfairLock(initialState: "")
        let finished = OSAllocatedUnfairLock(initialState: false)
        private let listener: NWListener
        private let queue = DispatchQueue(label: "vocaphone.test-upload-server")
        private var connection: NWConnection?
        private var wire = Data()
        private var parsedHeaders = false
        private let reject: Bool
        private let holdResponse: Bool
        private var bodyLength: Int?

        init(reject: Bool = false, holdResponse: Bool = false) throws {
            self.reject = reject
            self.holdResponse = holdResponse
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [self] connection in
                self.connection = connection
                connection.start(queue: queue)
                receive(connection)
            }
            return try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: listener.port!.rawValue)
                    case let .failed(error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func cancel() {
            listener.cancel()
            queue.async { self.connection?.cancel() }
        }

        private func receive(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, end, error in
                if let data { wire.append(data) }
                if parse(connection) { return }
                if !end, error == nil { receive(connection) }
            }
        }

        private func parse(_ connection: NWConnection) -> Bool {
            if !parsedHeaders {
                guard let range = wire.range(of: Data("\r\n\r\n".utf8)) else { return false }
                let header = String(decoding: wire[..<range.lowerBound], as: UTF8.self)
                headers.withLock { $0 = header }
                if let length = header.lowercased().components(separatedBy: "\r\n")
                    .first(where: { $0.hasPrefix("content-length:") })?.split(separator: ":").last {
                    bodyLength = Int(length.trimmingCharacters(in: .whitespaces))
                }
                wire.removeSubrange(..<range.upperBound)
                parsedHeaders = true
                if reject {
                    reply(connection, status: 503, body: "{\"error\":{\"code\":\"unavailable\"}}")
                    return true
                }
            }
            if let bodyLength {
                received.withLock { $0.append(wire) }
                wire.removeAll()
                guard received.withLock({ $0.count }) >= bodyLength else { return false }
                respondToUpload(connection)
                return true
            }
            while let range = wire.range(of: Data("\r\n".utf8)) {
                guard let count = Int(String(decoding: wire[..<range.lowerBound], as: UTF8.self), radix: 16),
                      wire.count >= range.upperBound + count + 2 else { return false }
                if count == 0 {
                    respondToUpload(connection)
                    return true
                }
                received.withLock { $0.append(wire[range.upperBound..<(range.upperBound + count)]) }
                wire.removeSubrange(..<(range.upperBound + count + 2))
            }
            return false
        }

        private func respondToUpload(_ connection: NWConnection) {
            finished.withLock { $0 = true }
            guard !holdResponse else { return }
            let body = "{\"session_id\":\"00000000-0000-0000-0000-000000000001\",\"job_id\":\"test\",\"state\":\"uploaded\"}"
            reply(connection, status: reject ? 503 : 200, body: body)
        }

        private func reply(_ connection: NWConnection, status: Int, body: String) {
            let response = "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
