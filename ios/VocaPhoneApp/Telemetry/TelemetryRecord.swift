import Foundation

/// The device and build facts attached to every event.
///
/// ## Why this is narrower than Aptabase's own SDK
///
/// `aptabase-swift` auto-populates `systemProps` with `deviceModel` and a full
/// `osVersion`. Both are omitted or coarsened here, on purpose:
///
/// - **No `deviceModel` at all.** App Store Connect already reports the device
///   distribution for every install, not just opted-in ones, so sending it here
///   buys nothing — while model plus exact OS build plus locale is a usable
///   fingerprint at beta population sizes, which would undo most of what the
///   daily-rotating server-side hash achieves.
/// - **`osVersion` is the major only** — `"18"`, never `"18.1.1"`. Enough to
///   decide what to keep supporting, not enough to narrow anyone down.
/// - **`locale` is the language subtag only** — `"en"`, never `"en-IN"`. The
///   region is the identifying half and is not needed to know which languages
///   matter.
///
/// Sending less than the SDK sends is trivial when you own the request and
/// requires a fork when you do not. That is the main reason this client is
/// hand-rolled, and `TelemetryTests` fails the build if a field creeps back in.
struct TelemetrySystemProps: Codable, Equatable, Sendable {
    let locale: String
    let osName: String
    let osVersion: String
    let isDebug: Bool
    let appVersion: String
    let sdkVersion: String

    /// The complete set of keys that may appear. Asserted by test.
    static let keys: Set<String> = [
        "locale", "osName", "osVersion", "isDebug", "appVersion", "sdkVersion",
    ]

    static func current(bundle: Bundle = .main) -> TelemetrySystemProps {
        #if DEBUG
            let debugBuild = true
        #else
            let debugBuild = false
        #endif
        return TelemetrySystemProps(
            locale: languageSubtag(Locale.current),
            osName: "iOS",
            osVersion: String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            isDebug: debugBuild,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "0",
            sdkVersion: TelemetryConfig.sdkVersion
        )
    }

    /// `"en"` from `en_IN`, and `"und"` — the ISO 639-2 code for an undetermined
    /// language — when the platform gives nothing usable. A fixed placeholder
    /// keeps the column parseable rather than mixing empty strings into it.
    static func languageSubtag(_ locale: Locale) -> String {
        guard let code = locale.language.languageCode?.identifier.lowercased(),
            code.count >= 2, code.count <= 3,
            code.allSatisfy({ $0.isLetter })
        else { return "und" }
        return code
    }

    /// `"18"` from `"18"`, `"18.1"` or `"18.1.1"`, and `"0"` when the platform
    /// reports something unparseable. Digits only, so the column can be sorted
    /// and grouped without cleaning.
    static func majorVersion(_ release: String?) -> String {
        let major = (release ?? "").split(separator: ".").first.map(String.init) ?? ""
        let digits = major.filter(\.isNumber)
        return digits.isEmpty ? "0" : digits
    }
}

/// One event, in the shape Aptabase's `POST /api/v0/events` accepts.
///
/// `props` is a `[String: String]` only because JSON needs one at the edge.
/// Nothing outside this file can populate it with an arbitrary string:
/// ``Telemetry`` builds every entry from the enums in `TelemetryEvent.swift`,
/// and the initialiser is `fileprivate` to everything but that type.
struct TelemetryRecord: Codable, Equatable, Sendable {
    let timestamp: Date
    let sessionId: String
    let eventName: String
    let systemProps: TelemetrySystemProps
    let props: [String: String]

    /// Aptabase's documented timestamp format, milliseconds and a literal Z.
    ///
    /// Always UTC: a local offset would carry the user's timezone, which is a
    /// coarse location and has no business in an anonymous event.
    ///
    /// Built fresh per encode rather than cached in a `static let`, because
    /// `ISO8601DateFormatter` is not `Sendable` and a shared mutable formatter
    /// is a real data race, not a theoretical one. At the handful of events a
    /// session produces, the allocation does not matter.
    static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted so the "See what's sent" screen renders the same order every
        // time; a payload that reshuffles between viewings looks like it is
        // hiding something.
        encoder.outputFormatting = [.sortedKeys]
        let formatter = timestampFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
}

extension Array where Element == TelemetryRecord {
    /// What actually goes over the wire: a JSON array, at most
    /// ``TelemetryConfig/maxBatch`` long.
    func requestBody() throws -> Data {
        try TelemetryRecord.encoder().encode(self)
    }
}
