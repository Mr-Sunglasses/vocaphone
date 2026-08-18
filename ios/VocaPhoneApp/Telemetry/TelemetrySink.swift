import Foundation

/// The outcome of one attempted batch. Determines whether it is worth retrying.
enum TelemetryDelivery: Sendable {
    /// The server took it.
    case delivered

    /// The server refused it and always will — a bad app key, a malformed
    /// payload, a schema the server no longer accepts. Retrying is pointless
    /// and the batch is dropped.
    case rejected

    /// Transient: no network, a 5xx, a timeout. Worth exactly one more try.
    case unavailable
}

protocol TelemetrySink: Sendable {
    func send(_ batch: [TelemetryRecord]) async -> TelemetryDelivery
}

/// What DEBUG builds and every unit test bind.
///
/// Events still queue behind it, which is deliberate: it is what makes the
/// "See what's sent" screen work while developing the feature, without a byte
/// leaving the phone.
struct NoOpTelemetrySink: TelemetrySink {
    func send(_ batch: [TelemetryRecord]) async -> TelemetryDelivery { .delivered }
}

/// The only code in this app that sends usage data anywhere.
///
/// Roughly a hundred lines against Aptabase's documented ingest API, rather than
/// its MIT-licensed Swift SDK. The dependency is not the problem — the SDK's
/// `systemProps` is, since it auto-populates `deviceModel` and a full
/// `osVersion` that this app deliberately does not send (see
/// ``TelemetrySystemProps``). Owning the request is what makes omitting them a
/// one-line decision instead of a fork, and it keeps "no analytics SDK" true in
/// the README and the App Store listing.
struct AptabaseSink: TelemetrySink {
    let url: URL
    let appKey: String
    let session: URLSession

    init(
        url: URL? = TelemetryConfig.ingestURL,
        appKey: String = TelemetryConfig.appKey,
        session: URLSession = AptabaseSink.defaultSession()
    ) {
        // A malformed host is a build-time mistake, not a runtime condition to
        // handle on every send; falling back to a URL that cannot resolve keeps
        // the type non-optional and the failure silent, which is what a
        // telemetry failure should always be.
        self.url = url ?? URL(string: "https://invalid.invalid")!
        self.appKey = appKey
        self.session = session
    }

    func send(_ batch: [TelemetryRecord]) async -> TelemetryDelivery {
        guard !batch.isEmpty else { return .delivered }
        guard let body = try? batch.requestBody() else { return .rejected }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(appKey, forHTTPHeaderField: "App-Key")
        // Not set to anything identifying. Aptabase hashes the User-Agent
        // together with the IP and its daily salt to derive the anonymous user,
        // so this string is an input to that hash and nothing else; a
        // version-only value keeps it from carrying device detail.
        request.setValue(TelemetryConfig.sdkVersion, forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            switch http.statusCode {
            case 200..<300: return .delivered
            // 4xx is the server saying this payload is wrong, not that it is
            // busy. Retrying a rejected batch just burns battery on a request
            // that cannot succeed.
            case 400..<500: return .rejected
            default: return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    /// Short timeouts, no cellular-hostile retry behaviour, and no caching:
    /// nothing here is worth making a user's phone wait or storing on their
    /// disk.
    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}
