import Foundation

struct GatewayHealth: Decodable, Sendable {
    let status: String
    let engineReady: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case engineReady = "engine_ready"
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
        request.httpBody = try Data(contentsOf: fileURL)
        return try await perform(request, as: GatewaySession.self)
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

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
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
        authenticated: Bool = true
    ) async throws -> T {
        var request = original
        if authenticated {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GatewayError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            throw GatewayError.api(status: http.statusCode, code: body?.error.code ?? "unknown")
        }
        return try JSONDecoder().decode(type, from: data)
    }
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
            "The Mac returned an invalid response."
        case let .api(status, code):
            "Gateway error \(status): \(code)"
        }
    }
}
