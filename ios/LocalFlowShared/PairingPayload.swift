import Foundation

/// The versioned document encoded in the gateway WebUI's phone-pairing QR.
///
/// Version 1 wire format:
/// `{"v":1,"url":"http://192.168.1.20:8765","token":"..."}`
enum PairingPayload {
    static let version = 1

    struct Value: Equatable {
        let url: URL
        let token: String
    }

    enum Result: Equatable {
        case success(Value)
        case failure(String)
    }

    static func parse(_ rawValue: String) -> Result {
        let rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else {
            return .failure("The pairing code is empty.")
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: Data(rawValue.utf8))
        } catch {
            return .failure("This is not a Local Flow pairing code.")
        }

        guard document.supportedVersion == version else {
            return .failure("This pairing code uses an unsupported version.")
        }

        let urlString = document.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = document.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else {
            return .failure("The pairing code is missing a gateway address.")
        }
        guard !token.isEmpty else {
            return .failure("The pairing code is missing a bearer token.")
        }
        guard token.count >= 32 else {
            return .failure("The pairing token looks too short to be valid.")
        }
        guard let url = GatewayEndpoint.validatedURL(from: urlString) else {
            return .failure("The pairing code has an invalid gateway address.")
        }
        if GatewayEndpoint.usesUnencryptedHTTP(url),
           !GatewayEndpoint.isPrivateNetworkHost(url.host ?? "")
        {
            let host = url.host ?? "This host"
            return .failure(
                "\(host) is reachable from the public internet, so it needs https://."
            )
        }

        return .success(Value(url: url, token: token))
    }
}

private extension PairingPayload {
    struct Document: Decodable {
        let v: Int?
        let legacyVersion: Int?
        let url: String
        let token: String

        enum CodingKeys: String, CodingKey {
            case v
            case legacyVersion = "version"
            case url
            case token
        }

        var supportedVersion: Int? { v ?? legacyVersion }
    }
}
