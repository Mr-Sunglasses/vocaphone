import Foundation
import Testing
import os

struct GatewayLanguageFallbackTests {
    // MARK: When to resend

    @Test func onlyARefusalOfAChosenLanguageIsResent() {
        #expect(GatewayLanguageFallback.shouldResend(code: "language_unsupported", language: "hi"))
        #expect(GatewayLanguageFallback.shouldResend(code: "language_unsupported", language: "en"))
        // Automatic has nothing to fall back to.
        #expect(!GatewayLanguageFallback.shouldResend(code: "language_unsupported", language: "auto"))
        #expect(!GatewayLanguageFallback.shouldResend(code: "transcription_failed", language: "hi"))
        #expect(!GatewayLanguageFallback.shouldResend(code: "silent_audio", language: "hi"))
    }

    // MARK: Which Automatic answers stand in

    @Test func theRequestedAlphabetAndLatinAreKept() {
        #expect(GatewayLanguageFallback.accepts("नमस्ते, कैसे हो?", for: "hi"))
        // Said in English, or in romanised Hindi: those were the words.
        #expect(GatewayLanguageFallback.accepts("Send me the report by Friday.", for: "hi"))
        #expect(GatewayLanguageFallback.accepts("kal milte hain", for: "hi"))
        #expect(GatewayLanguageFallback.accepts("मैं report Friday तक send करूंगा", for: "hi"))
        #expect(GatewayLanguageFallback.accepts("Привет, как дела?", for: "ru"))
        #expect(GatewayLanguageFallback.accepts("こんにちは、元気ですか", for: "ja"))
        #expect(GatewayLanguageFallback.accepts("안녕하세요", for: "ko"))
        #expect(GatewayLanguageFallback.accepts("你好", for: "zh-Hans"))
    }

    @Test func anUnrelatedAlphabetIsRefused() {
        // The detecting models' known misreads of short Hindi phrases.
        #expect(!GatewayLanguageFallback.accepts("Намасте", for: "hi"))
        #expect(!GatewayLanguageFallback.accepts("好的", for: "hi"))
        #expect(!GatewayLanguageFallback.accepts("مرحبا", for: "ta"))
    }

    @Test func latinLanguagesAndLetterlessTextAreNotChecked() {
        #expect(GatewayLanguageFallback.accepts("नमस्ते", for: "en"))
        #expect(GatewayLanguageFallback.accepts("Bonjour", for: "fr"))
        #expect(GatewayLanguageFallback.accepts("42 + 7", for: "hi"))
    }

    @Test func aMisreadHasItsOwnShortWording() {
        let failure = DictationFailure(code: GatewayLanguageFallback.misreadCode)
        #expect(failure == .languageMisread)
        #expect(failure.keyboardTitle.count < 60)
        #expect(failure.keyboardLine.count < 60)
        #expect(!GatewayLanguageFallback.misreadMessage.contains("Settings"))
    }

    // MARK: The resend

    @Test func theRecordingIsResentAsAutomaticInAFreshSession() async throws {
        let refused = UUID()
        let gateway = StubGateway(finishReply: (200, completed("नमस्ते")))
        let transcript = try await gateway.client.resendAsAutomatic(
            refusedSessionID: refused, fileURL: try recording(), requested: "hi", style: "casual"
        )
        #expect(transcript == "नमस्ते")
        let requests = gateway.requests
        try #require(requests.count == 3)
        #expect(requests[0].line == "DELETE /v1/sessions/\(refused.uuidString.lowercased())")
        #expect(requests[1].line == "POST /v1/sessions")
        #expect(requests[2].line.hasPrefix("PUT /v1/sessions/"))
        #expect(!requests[2].line.contains(refused.uuidString.lowercased()))
        let body = try JSONSerialization.jsonObject(with: requests[1].body) as? [String: String]
        #expect(body?["language"] == "auto")
        #expect(body?["client_session_id"] != refused.uuidString.lowercased())
    }

    @Test func anAnswerInAnotherAlphabetIsAMisreadAndIsDeleted() async throws {
        let gateway = StubGateway(finishReply: (200, completed("Намасте")))
        await expectMisread(gateway)
        // The transcript it did produce is not left on the gateway.
        let requests = gateway.requests
        #expect(requests.count == 4)
        #expect(requests.last?.line.hasPrefix("DELETE /v1/sessions/") == true)
        #expect(requests.last?.line == requests[2].line
            .replacingOccurrences(of: "PUT ", with: "DELETE ")
            .replacingOccurrences(of: "/audio", with: ""))
    }

    @Test func aSecondRefusalIsAMisread() async throws {
        await expectMisread(StubGateway(finishReply: (422, "{\"error\":{\"code\":\"language_unsupported\"}}")))
    }

    @Test func noSpeechIsPassedOnAsItCame() async throws {
        let gateway = StubGateway(finishReply: (422, "{\"error\":{\"code\":\"silent_audio\"}}"))
        do {
            _ = try await gateway.client.resendAsAutomatic(
                refusedSessionID: UUID(), fileURL: try recording(), requested: "hi", style: "casual"
            )
            Issue.record("Expected a failure")
        } catch let GatewayError.api(_, code) {
            #expect(code == "silent_audio")
        }
    }

    // MARK: Helpers

    private func expectMisread(_ gateway: StubGateway) async {
        do {
            _ = try await gateway.client.resendAsAutomatic(
                refusedSessionID: UUID(), fileURL: try recording(), requested: "hi", style: "casual"
            )
            Issue.record("Expected a misread")
        } catch let GatewayError.api(_, code) {
            #expect(code == GatewayLanguageFallback.misreadCode)
        } catch {
            Issue.record("Unexpected \(error)")
        }
    }

    private func completed(_ transcript: String) -> String {
        "{\"session_id\":\"\(UUID())\",\"job_id\":\"j\",\"state\":\"completed\",\"transcript\":\"\(transcript)\"}"
    }

    /// Not a WAV, so the upload sends it as it is rather than encoding it.
    private func recording() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("language-fallback-\(UUID().uuidString).m4a")
        try Data(repeating: 1, count: 256).write(to: url)
        return url
    }
}

/// A gateway that answers by route, told apart from other tests' by its token.
private final class StubGateway: @unchecked Sendable {
    struct Request { let line: String; let body: Data }

    let client: GatewayClient
    private let token = UUID().uuidString
    private let session: URLSession

    init(finishReply: (Int, String)) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubGatewayProtocol.self]
        session = URLSession(configuration: configuration)
        client = GatewayClient(baseURL: URL(string: "http://gateway.test")!, token: token, session: session)
        StubGatewayProtocol.state.withLock { $0[token] = (finishReply, []) }
    }

    deinit {
        session.invalidateAndCancel()
        StubGatewayProtocol.state.withLock { $0[token] = nil }
    }

    var requests: [Request] {
        StubGatewayProtocol.state.withLock { $0[token]?.requests ?? [] }
    }
}

private final class StubGatewayProtocol: URLProtocol {
    typealias Entry = (finishReply: (Int, String), requests: [StubGateway.Request])
    static let state = OSAllocatedUnfairLock(initialState: [String: Entry]())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization")?
            .replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let line = "\(method) \(path)"
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let reply: (Int, String) = Self.state.withLock { state in
            state[token]?.requests.append(.init(line: line, body: body))
            switch method {
            case "DELETE": return (200, "{\"deleted\":true}")
            case "POST" where path == "/v1/sessions":
                return (200, "{\"session_id\":\"\(UUID())\",\"job_id\":\"j\",\"state\":\"created\"}")
            default: return state[token]?.finishReply ?? (500, "{}")
            }
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
