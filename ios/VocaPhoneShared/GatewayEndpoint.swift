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

    /// Cleartext pairing is restricted to networks the user controls. This
    /// matches the Android pairing contract; a bearer token must never be
    /// accepted from a QR code pointing to public HTTP.
    static func isPrivateNetworkHost(_ host: String) -> Bool {
        let name = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty else { return false }
        if name == "localhost" || isPrivateIPv4(name) || isPrivateIPv6(name) {
            return true
        }
        if looksLikeIPv4(name) || name.contains(":") { return false }
        if name.hasSuffix(".local") || name.hasSuffix(".internal") || name.hasSuffix(".home.arpa") {
            return true
        }
        if name == "ts.net" || name.hasSuffix(".ts.net") { return true }
        return !name.contains(".")
    }

    private static func looksLikeIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        guard looksLikeIPv4(host) else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254), (100, 64...127):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        let name = host.lowercased().split(separator: "%", maxSplits: 1).first ?? ""
        guard name.contains(":"), name != "::1" else { return name == "::1" }
        let firstGroup = name.split(separator: ":", omittingEmptySubsequences: false).first ?? ""
        let paddedGroup = String(repeating: "0", count: max(0, 4 - firstGroup.count))
            + String(firstGroup)
        guard let prefix = Int(paddedGroup, radix: 16) else { return false }
        return (0xfc00...0xfdff).contains(prefix) || (0xfe80...0xfebf).contains(prefix)
    }
}
