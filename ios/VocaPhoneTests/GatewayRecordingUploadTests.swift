import Foundation
import Network
import Testing
import os

struct GatewayRecordingUploadTests {
    @Test(arguments: [true, false])
    func liveTransportUsesTheUploadTranscriptOrOneLegacyFinish(combined: Bool) async throws {
        let id = UUID()
        let completed = "{\"session_id\":\"\(id)\",\"job_id\":\"test\",\"state\":\"completed\",\"transcript\":\"Hello there\"}"
        let uploaded = "{\"session_id\":\"\(id)\",\"job_id\":\"test\",\"state\":\"uploaded\"}"
        var replies = ["{\"status\":\"ok\",\"engine_ready\":true,\"engine\":\"test\"}", uploaded, combined ? completed : uploaded]
        if !combined { replies.append(completed) }
        let server = try UploadServer(responses: replies)
        let port = try await server.start()
        defer { server.cancel() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let client = GatewayClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: "test-token", session: session)
        let transport = try await client.recordingTransport(
            sessionID: id, language: "en", style: "raw", sampleRate: 16_000,
            attemptTranscriptionStream: false
        )
        defer { transport.cancel() }
        let samples: [Float] = [0, -1, 1]
        try await transport.send(samples.withUnsafeBytes { Data($0) })
        #expect(try await transport.finish() == "Hello there")
        let requests = server.requests.withLock { $0 }
        #expect(requests.count == (combined ? 3 : 4))
        #expect(requests[2].lowercased().contains("/audio?finish=true"))
        #expect(requests[2].hasPrefix("PUT "))
        if !combined { #expect(requests[3].hasPrefix("POST ")) }
    }

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

    @Test func liveUploadReportsBodyCompletionWhileTheTranscriptIsPending() async throws {
        let server = try UploadServer(holdResponse: true)
        let port = try await server.start()
        defer { server.cancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/audio?finish=true")!)
        request.httpMethod = "PUT"
        let notifications = OSAllocatedUnfairLock(initialState: 0)
        let upload = try GatewayRecordingUpload(request: request, configuration: .ephemeral,
                                                onUploadFinished: { notifications.withLock { $0 += 1 } })
        defer { upload.cancel() }
        try await upload.sendHeader()
        try await upload.send(Data(repeating: 0, count: 6_400))
        #expect(notifications.withLock { $0 } == 0)
        let finishing = Task { try await upload.finish() }
        defer { finishing.cancel() }
        try await waitUntil { server.finished.withLock { $0 } && notifications.withLock { $0 } == 1 }
        #expect(notifications.withLock { $0 } == 1)
        finishing.cancel()
        await #expect(throws: CancellationError.self) { try await finishing.value }
        #expect(notifications.withLock { $0 } == 1)
    }

    @Test func progressWaitsForEOFAndNotifiesOnlyOnce() async {
        let notifications = OSAllocatedUnfairLock(initialState: 0)
        let progress = GatewayUploadProgress { notifications.withLock { $0 += 1 } }
        progress.sent(bytes: 44)
        await progress.waitForNotification()
        #expect(notifications.withLock { $0 } == 0)
        progress.bodyClosed(bytes: 50)
        progress.sent(bytes: 50)
        progress.sent(bytes: 50)
        progress.bodyClosed(bytes: 50)
        await progress.waitForNotification()
        #expect(notifications.withLock { $0 } == 1)
        let cancelled = GatewayUploadProgress { notifications.withLock { $0 += 1 } }
        cancelled.cancel()
        cancelled.bodyClosed(bytes: 44)
        cancelled.sent(bytes: 44)
        await cancelled.waitForNotification()
        #expect(notifications.withLock { $0 } == 1)
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
        let requests = OSAllocatedUnfairLock(initialState: [String]())
        private let listener: NWListener
        private let queue = DispatchQueue(label: "vocaphone.test-upload-server")
        private var connection: NWConnection?
        private var wire = Data()
        private var parsedHeaders = false
        private let reject: Bool
        private let holdResponse: Bool
        private var bodyLength: Int?
        private let responses: [String]
        private var responseIndex = 0

        init(reject: Bool = false, holdResponse: Bool = false, responses: [String] = []) throws {
            self.reject = reject
            self.holdResponse = holdResponse
            self.responses = responses
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [self] connection in
                self.connection = connection
                wire.removeAll()
                parsedHeaders = false
                bodyLength = nil
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
                requests.withLock { $0.append(header) }
                if let length = header.lowercased().components(separatedBy: "\r\n")
                    .first(where: { $0.hasPrefix("content-length:") })?.split(separator: ":").last {
                    bodyLength = Int(length.trimmingCharacters(in: .whitespaces))
                }
                if bodyLength == nil, !header.lowercased().contains("transfer-encoding: chunked") {
                    bodyLength = 0
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
            let body: String
            if responses.isEmpty {
                body = "{\"session_id\":\"00000000-0000-0000-0000-000000000001\",\"job_id\":\"test\",\"state\":\"uploaded\"}"
            } else {
                guard responseIndex < responses.count else {
                    reply(connection, status: 500, body: "{\"error\":{\"code\":\"unexpected_request\"}}")
                    return
                }
                body = responses[responseIndex]
                responseIndex += 1
            }
            reply(connection, status: reject ? 503 : 200, body: body)
        }

        private func reply(_ connection: NWConnection, status: Int, body: String) {
            let response = "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
