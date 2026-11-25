import Foundation
import Security

/// The gateway's bearer token.
///
/// Kept in the App Group's keychain access group, so the keyboard can send a
/// recording to the gateway itself instead of opening vocaphone to do it. iOS
/// lets an App Group name act as a keychain access group for every bundle that
/// carries the group's entitlement, so this needs no entitlement of its own.
///
/// Tokens saved by older builds live in the app's default access group, which
/// the keyboard cannot read. ``loadToken()`` moves such a token across the
/// first time the app reads it; ``loadSharedToken()`` is the keyboard's read and
/// never looks anywhere else.
enum KeychainStore {
    private static let service = "com.vocahq.vocaphone.gateway"
    private static let account = "bearer-token"

    private static var sharedAccessGroup: String { AppConfiguration.appGroupIdentifier }

    static func saveToken(_ token: String) throws {
        do {
            try upsert(token, accessGroup: sharedAccessGroup)
        } catch KeychainError.status(errSecMissingEntitlement) {
            // A build whose signature does not carry the group (an unsigned
            // test host) keeps working for the app; the keyboard then opens
            // vocaphone as it always has.
            try upsert(token, accessGroup: nil)
            return
        }
        // Only once the shared copy is safely written: a token is never left
        // with no copy at all, which would mean pairing again.
        deleteOutsideSharedGroup()
    }

    /// The app's read: the shared item first, then a token an older build left
    /// in the app's own group, copied into the shared group on the way.
    static func loadToken() throws -> String? {
        if let shared = try load(accessGroup: sharedAccessGroup) { return shared }
        guard let legacy = try load(accessGroup: nil) else { return nil }
        try? saveToken(legacy)
        return legacy
    }

    /// The keyboard's read. Nil until the app has saved or migrated the token.
    static func loadSharedToken() -> String? {
        (try? load(accessGroup: sharedAccessGroup)) ?? nil
    }

    private static func baseQuery(accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    /// Updates the item in place, or adds it: never a delete followed by an
    /// add that might fail.
    private static func upsert(_ token: String, accessGroup: String?) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = baseQuery(accessGroup: accessGroup)
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError.status(updated) }
        var item = baseQuery(accessGroup: accessGroup)
        item.merge(attributes) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
    }

    /// The legacy copy, in whatever group the app's default is. Its group is
    /// read from the item itself rather than assumed, since it carries the
    /// team prefix.
    private static func deleteOutsideSharedGroup() {
        var query = baseQuery(accessGroup: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return }
        for item in items {
            guard let group = item[kSecAttrAccessGroup as String] as? String,
                  group != sharedAccessGroup
            else { continue }
            SecItemDelete(baseQuery(accessGroup: group) as CFDictionary)
        }
    }

    private static func load(accessGroup: String?) throws -> String? {
        var query = baseQuery(accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecMissingEntitlement { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.status(status)
        }
        return String(data: data, encoding: .utf8)
    }
}

enum KeychainError: Error {
    case status(OSStatus)
}
