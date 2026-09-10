import Foundation
import Testing

struct StatsPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_778_457_600)

    private var stats: UsageStats {
        UsageStats(
            totalWords: 12_500,
            totalDictations: 42,
            totalSeconds: 3_600,
            lastDayKey: UsageStats.dayKey(now),
            currentStreak: 4,
            bestStreak: 9
        )
    }

    private func xPostLength(_ message: String) -> Int {
        let withoutURL = message.replacingOccurrences(of: StatsShareComposer.site, with: "")
        let weighted = withoutURL.unicodeScalars.reduce(0) { total, scalar in
            switch scalar.value {
            case 0...4351, 8192...8205, 8208...8223, 8242...8247:
                return total + 1
            default:
                return total + 2
            }
        }
        return weighted + 23
    }

    @Test func shareCopyNamesBothPrivateProcessingRoutes() {
        let message = StatsShareComposer.message(stats, now: now, destination: .x)
        #expect(message.contains("I’ve spoken 12,500 words with VocaPhone"))
        #expect(message.contains("1 hour of talking"))
        #expect(message.contains("my phone or my own self-hosted gateway"))
        #expect(message.contains("My audio stays mine"))
        #expect(message.contains("@vocahq"))
        #expect(message.contains(StatsShareComposer.site))
    }

    @Test func linkedinCopyOmitsTheXHandle() {
        let message = StatsShareComposer.message(stats, now: now, destination: .linkedIn)
        #expect(!message.contains("@vocahq"))
        #expect(message.hasSuffix(StatsShareComposer.site))
    }

    @Test func shareCopyFitsWithinTheXPostLimit() {
        let large = UsageStats(
            totalWords: 987_654_321,
            totalDictations: 123_456,
            totalSeconds: 9_000_000,
            lastDayKey: UsageStats.dayKey(now),
            currentStreak: 4_321,
            bestStreak: 5_000
        )
        let message = StatsShareComposer.message(large, now: now, destination: .x)
        #expect(xPostLength(message) <= 280)
    }

    @Test func shareCopyOmitsUnavailableDetailsAndShortDurations() {
        let empty = UsageStats(totalWords: 1, totalDictations: 0, totalSeconds: 0)
        let message = StatsShareComposer.message(empty, now: now, destination: .x)
        #expect(message.contains("1 word"))
        #expect(!message.contains("session"))
        #expect(!message.contains("talking"))
        #expect(!message.contains("WPM"))
        #expect(!message.contains("streak"))
        #expect(!message.contains("\n\n\n"))
        #expect(StatsShareComposer.spokenDuration(59) == nil)
        #expect(StatsShareComposer.spokenDuration(5_460) == "1 hour, 31 minutes")
    }

    @Test func xComposerURLRoundTripsTheEntireMessage() throws {
        let message = "words & sessions + streak; हिन्दी 🔒"
        let url = try #require(StatsShareComposer.composerURL(.x, message: message))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        #expect(items.first(where: { $0.name == "text" })?.value == message)
    }

    @Test func xNativeComposerRoundTripsTheEntireMessage() throws {
        let message = "words & sessions + streak; हिन्दी 🔒"
        let url = try #require(StatsShareComposer.nativeURL(.x, message: message))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "twitter")
        #expect(components.host == "post")
        #expect(components.queryItems?.first(where: { $0.name == "message" })?.value == message)
    }

    @Test func linkedinNativeRouteOpensTheInstalledApp() throws {
        let url = try #require(StatsShareComposer.nativeURL(.linkedIn, message: "hello"))
        #expect(url.scheme == "linkedin")
    }

    @Test(arguments: StatsShareDestination.allCases)
    func anInstalledAppIsPreferredOverTheBrowser(_ destination: StatsShareDestination) throws {
        let route = try #require(
            StatsShareComposer.preferredRoute(destination, message: "hello") { url in
                url.scheme != "https"
            }
        )
        #expect(route.target == .installedApp)
        #expect(route.url.scheme != "https")
    }

    @Test(arguments: StatsShareDestination.allCases)
    func theBrowserIsTheFallbackWithoutAnInstalledApp(
        _ destination: StatsShareDestination
    ) throws {
        let route = try #require(
            StatsShareComposer.preferredRoute(destination, message: "hello") { _ in false }
        )
        #expect(route.target == .browser)
        #expect(route.url.scheme == "https")
    }

    @Test func linkedinFeedComposerReceivesTheEntireMessage() throws {
        let message = "words & sessions + streak; हिन्दी 🔒"
        let url = try #require(StatsShareComposer.composerURL(.linkedIn, message: message))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "www.linkedin.com")
        #expect(components.path == "/feed/")
        #expect(components.queryItems?.first(where: { $0.name == "shareActive" })?.value == "true")
        #expect(components.queryItems?.first(where: { $0.name == "text" })?.value == message)
    }

    @Test func singularPublicCopyIsGrammatical() {
        let one = UsageStats(
            totalWords: 1,
            totalDictations: 1,
            totalSeconds: 1,
            lastDayKey: UsageStats.dayKey(now),
            currentStreak: 1,
            bestStreak: 1
        )
        let message = StatsShareComposer.message(one, now: now, destination: .x)
        #expect(message.contains("1 word"))
        #expect(message.contains("1 session"))
        #expect(!message.contains("1 sessions"))
    }

    @Test func chartLabelsStayDistinctAndLargeCountsStayCompact() {
        let utc = TimeZone(secondsFromGMT: 0) ?? .current
        #expect(StatsFormat.shortDayLabel("2026-09-08", timeZone: utc) == "Tue")
        #expect(StatsFormat.shortDayLabel("2026-09-10", timeZone: utc) == "Thu")
        #expect(StatsFormat.compactCount(1_200) == "1.2K")
        #expect(StatsFormat.compactCount(12_000) == "12K")
    }

    @Test func appInfoAllowsInstalledSocialAppDetection() throws {
        let infoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VocaPhoneApp/Info.plist")
        let plist = try #require(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: infoURL),
                format: nil
            ) as? [String: Any]
        )
        let schemes = try #require(plist["LSApplicationQueriesSchemes"] as? [String])
        #expect(Set(schemes).isSuperset(of: ["twitter", "linkedin"]))
    }
}
