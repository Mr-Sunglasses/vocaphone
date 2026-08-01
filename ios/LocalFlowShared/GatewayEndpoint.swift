import Foundation

enum GatewayEndpoint {
    static func validatedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }

        components.scheme = scheme
        return components.url
    }

    static func usesUnencryptedHTTP(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http"
    }
}
