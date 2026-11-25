import Foundation

/// What the keyboard needs to send a recording to the gateway by itself.
///
/// The app keeps the gateway address in its own defaults, which the keyboard
/// cannot read. It mirrors the address here only after it has a token and a
/// valid URL for it, and clears it when either goes away, so the keyboard never
/// records for a gateway the app would refuse to use. The token is in the
/// shared keychain group (``KeychainStore``), never in these defaults.
enum KeyboardGatewayAccess {
    static let baseURLKey = "keyboardGatewayBaseURL"
    static let maximumDurationKey = "keyboardGatewayMaximumDurationSeconds"
    static let enabledKey = "keyboardRecordsForGateway"
    static let streamingSupportedKey = "keyboardGatewayStreamingSupported"
    static let streamingCheckedAtKey = "keyboardGatewayStreamingCheckedAt"

    nonisolated(unsafe) private static let defaults = UserDefaults(
        suiteName: AppConfiguration.appGroupIdentifier
    )

    /// "Dictate without leaving the app" in Settings. On unless turned off: the
    /// keyboard falls back to opening vocaphone whenever it cannot record.
    static var enabled: Bool {
        get {
            guard let defaults, defaults.object(forKey: enabledKey) != nil else { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set { defaults?.set(newValue, forKey: enabledKey) }
    }

    static var baseURL: URL? {
        defaults?.string(forKey: baseURLKey).flatMap(GatewayEndpoint.validatedURL(from:))
    }

    /// The longest recording the gateway last said it accepts, or nil when it
    /// has not said. Only meaningful for ``baseURL``.
    static var reportedMaximumDurationSeconds: Int? {
        let seconds = defaults?.integer(forKey: maximumDurationKey) ?? 0
        return seconds > 0 ? seconds : nil
    }

    /// Whether to open the incremental-decoding WebSocket before falling back
    /// to the streamed upload, by the same rule the app uses
    /// (``GatewayStreamingPolicy``): only a fresh "not supported" skips it.
    static func shouldAttemptStreaming(for baseURL: URL, now: Date = Date()) -> Bool {
        let known = defaults?.object(forKey: streamingSupportedKey) as? Bool
        return GatewayStreamingPolicy.shouldAttemptStreaming(
            supported: known,
            checkedAt: defaults?.object(forKey: streamingCheckedAtKey) as? Date,
            cachedBaseURL: Self.baseURL?.absoluteString,
            currentBaseURL: baseURL,
            now: now
        )
    }

    static func publish(
        baseURL: URL,
        maximumDurationSeconds: Int?,
        streamingSupported: Bool? = nil,
        streamingCheckedAt: Date? = nil
    ) {
        if defaults?.string(forKey: baseURLKey) != baseURL.absoluteString {
            defaults?.removeObject(forKey: maximumDurationKey)
            defaults?.removeObject(forKey: streamingSupportedKey)
            defaults?.removeObject(forKey: streamingCheckedAtKey)
        }
        defaults?.set(baseURL.absoluteString, forKey: baseURLKey)
        if let maximumDurationSeconds, maximumDurationSeconds > 0 {
            defaults?.set(maximumDurationSeconds, forKey: maximumDurationKey)
        }
        if let streamingSupported, let streamingCheckedAt {
            defaults?.set(streamingSupported, forKey: streamingSupportedKey)
            defaults?.set(streamingCheckedAt, forKey: streamingCheckedAtKey)
        }
    }

    static func clear() {
        for key in [baseURLKey, maximumDurationKey, streamingSupportedKey, streamingCheckedAtKey] {
            defaults?.removeObject(forKey: key)
        }
    }
}
