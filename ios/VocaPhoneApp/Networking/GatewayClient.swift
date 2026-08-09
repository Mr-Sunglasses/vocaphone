import Foundation

struct GatewayHealth: Decodable, Sendable {
    let status: String
    let engineReady: Bool
    let engine: String
    /// Optional so an updated app remains compatible with older gateways.
    let streamingSupported: Bool?
    /// Languages the loaded model covers. Absent or empty means the gateway made
    /// no claim, and the language picker must stay fully open.
    let languages: [String]?
    /// True when the model picks the language itself and cannot be pinned.
    let detectsLanguageAutomatically: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case engineReady = "engine_ready"
        case engine
        case streamingSupported = "streaming_supported"
        case languages
        case detectsLanguageAutomatically = "detects_language_automatically"
    }
}

enum GatewayStatusPreferences {
    static let healthMessageKey = "gatewayHealthMessage"
    static let engineKey = "gatewayEngine"
    static let engineReadyKey = "gatewayEngineReady"
    static let streamingSupportedKey = "gatewayStreamingSupported"
    static let streamingSupportKnownKey = "gatewayStreamingSupportKnown"
    static let streamingSupportCheckedAtKey = "gatewayStreamingSupportCheckedAt"
    static let streamingSupportBaseURLKey = "gatewayStreamingSupportBaseURL"

    /// Both the setup checklist and the settings screen read this state, so the
    /// writes live in one place rather than being duplicated per view.
    static func store(message: String, engine: String, ready: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(message, forKey: healthMessageKey)
        defaults.set(engine, forKey: engineKey)
        defaults.set(ready, forKey: engineReadyKey)
    }

    /// Records what the loaded model can be asked for. Written to the App Group
    /// rather than standard defaults, because the keyboard extension has its own
    /// language menu and must not offer choices the app has ruled out.
    ///
    /// A gateway that says nothing clears the restriction instead of keeping a
    /// stale one — being uninformed must never look like being unsupported.
    static func storeLanguageSupport(_ health: GatewayHealth?) {
        KeyboardPreferences.modelLanguages = Set(health?.languages ?? [])
        KeyboardPreferences.modelDetectsLanguage = health?.detectsLanguageAutomatically ?? false
    }

    static func storeStreamingSupport(_ supported: Bool?, for baseURL: URL?) {
        let defaults = UserDefaults.standard
        guard let supported, let baseURL else {
            defaults.removeObject(forKey: streamingSupportedKey)
            defaults.set(false, forKey: streamingSupportKnownKey)
            defaults.removeObject(forKey: streamingSupportCheckedAtKey)
            defaults.removeObject(forKey: streamingSupportBaseURLKey)
            return
        }
        defaults.set(supported, forKey: streamingSupportedKey)
        defaults.set(true, forKey: streamingSupportKnownKey)
        defaults.set(Date(), forKey: streamingSupportCheckedAtKey)
        defaults.set(baseURL.absoluteString, forKey: streamingSupportBaseURLKey)
    }

    static func shouldAttemptStreaming(for baseURL: URL, now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        let supported = defaults.bool(forKey: streamingSupportedKey)
        return GatewayStreamingPolicy.shouldAttemptStreaming(
            supported: defaults.bool(forKey: streamingSupportKnownKey) ? supported : nil,
            checkedAt: defaults.object(forKey: streamingSupportCheckedAtKey) as? Date,
            cachedBaseURL: defaults.string(forKey: streamingSupportBaseURLKey),
            currentBaseURL: baseURL,
            now: now
        )
    }
}

struct GatewaySession: Decodable, Sendable {
    let sessionID: UUID
    let jobID: String
    let state: String
    let transcript: String?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case jobID = "job_id"
        case state
        case transcript
        case errorCode = "error_code"
    }
}

private struct GatewayModel: Decodable, Sendable {
    let id: String
    let ready: Bool
    let local: Bool
}

struct GatewayClient: Sendable {
    let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func health() async throws -> GatewayHealth {
        var request = URLRequest(url: endpoint("health"))
        request.timeoutInterval = 2
        return try await perform(request, as: GatewayHealth.self, authenticated: false)
    }

    func verifyAuthentication() async throws {
        var request = URLRequest(url: endpoint("v1/models"))
        request.timeoutInterval = 5
        _ = try await perform(request, as: [GatewayModel].self)
    }

    func createSession(id: UUID, language: String, style: String) async throws -> GatewaySession {
        var request = URLRequest(url: endpoint("v1/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_session_id": id.uuidString.lowercased(),
            "language": language,
            "style": style,
        ])
        return try await perform(request, as: GatewaySession.self)
    }

    func uploadAudio(sessionID: UUID, fileURL: URL) async throws -> GatewaySession {
        var request = URLRequest(url: endpoint("v1/sessions/\(sessionID.uuidString.lowercased())/audio"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue(contentType(for: fileURL), forHTTPHeaderField: "Content-Type")
        // Streamed from disk rather than assigned to `httpBody`, which would
        // hold the entire recording in memory and then let URLSession copy it
        // again — on the path taken precisely when the network is struggling.
        return try await perform(request, as: GatewaySession.self, uploading: fileURL)
    }

    func finish(sessionID: UUID) async throws -> GatewaySession {
        var request = URLRequest(url: endpoint("v1/sessions/\(sessionID.uuidString.lowercased())/finish"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        return try await perform(request, as: GatewaySession.self)
    }

    func delete(sessionID: UUID) async throws {
        var request = URLRequest(url: endpoint("v1/sessions/\(sessionID.uuidString.lowercased())"))
        request.httpMethod = "DELETE"
        _ = try await perform(request, as: EmptyResponse.self)
    }

    func startAudioStream(
        sessionID: UUID,
        language: String,
        style: String,
        sampleRate: Int
    ) async throws -> GatewayAudioStream {
        // Negotiate support on the authenticated WebSocket itself. A separate
        // health preflight noticeably delays recording on mDNS hostnames whose
        // IPv6 address is advertised but not reachable (for example, a Docker
        // gateway published only on IPv4).
        let stream = GatewayAudioStream(
            url: websocketEndpoint("v1/stream"),
            token: token,
            sessionID: sessionID,
            language: language,
            style: style,
            sampleRate: sampleRate,
            session: session
        )
        try await stream.connect()
        return stream
    }

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    private func websocketEndpoint(_ path: String) -> URL {
        let httpURL = endpoint(path)
        var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false)!
        components.scheme = httpURL.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    private func contentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "caf": "audio/x-caf"
        default: "audio/mp4"
        }
    }

    private func perform<T: Decodable>(
        _ original: URLRequest,
        as type: T.Type,
        authenticated: Bool = true,
        uploading fileURL: URL? = nil
    ) async throws -> T {
        var request = original
        if authenticated {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = if let fileURL {
            try await session.upload(for: request, fromFile: fileURL)
        } else {
            try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw GatewayError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            throw GatewayError.api(status: http.statusCode, code: body?.error.code ?? "unknown")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

final class GatewayAudioStream: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let startPayload: [String: Any]

    init(
        url: URL,
        token: String,
        sessionID: UUID,
        language: String,
        style: String,
        sampleRate: Int,
        session: URLSession
    ) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request)
        startPayload = [
            "type": "start",
            "session_id": sessionID.uuidString.lowercased(),
            "language": language,
            "style": style,
            "sample_rate": sampleRate,
        ]
    }

    func connect() async throws {
        task.resume()
        let data = try JSONSerialization.data(withJSONObject: startPayload)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
        let event = try await receiveEvent()
        guard event.type == "ready" else { throw GatewayStreamError.handshakeFailed }
    }

    func send(_ pcmFloat32: Data) async throws {
        try await task.send(.data(pcmFloat32))
    }

    func finish() async throws -> String {
        let finish = try JSONSerialization.data(withJSONObject: ["type": "finish"])
        try await task.send(.string(String(decoding: finish, as: UTF8.self)))
        while true {
            let event = try await receiveEvent()
            switch event.type {
            case "complete":
                guard let transcript = event.transcript, !transcript.isEmpty else {
                    throw GatewayStreamError.emptyTranscript
                }
                task.cancel(with: .normalClosure, reason: nil)
                return transcript
            case "error":
                throw GatewayStreamError.serverRejected
            default:
                continue
            }
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }

    private func receiveEvent() async throws -> GatewayStreamEvent {
        let message = try await task.receive()
        let data: Data
        switch message {
        case let .data(value): data = value
        case let .string(value): data = Data(value.utf8)
        @unknown default: throw GatewayStreamError.invalidMessage
        }
        return try JSONDecoder().decode(GatewayStreamEvent.self, from: data)
    }
}

private struct GatewayStreamEvent: Decodable {
    let type: String
    let transcript: String?
}

private enum GatewayStreamError: Error {
    case handshakeFailed
    case emptyTranscript
    case serverRejected
    case invalidMessage
}

private struct APIErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String }
    let error: Detail
}

private struct EmptyResponse: Decodable {}

enum GatewayError: LocalizedError {
    case invalidResponse
    case api(status: Int, code: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The gateway returned an invalid response."
        case let .api(status, code):
            "Gateway error \(status): \(code)"
        }
    }
}
