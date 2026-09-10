import Foundation

enum StatsCopy {
    static let resetTitle = "Reset statistics?"
    static let resetBody =
        "This permanently deletes your usage totals. Your transcripts are not affected."
    static let resetConfirm = "Reset"
    static let speedCaption = "Average speaking speed"
    static let shareTitle = "Share your progress"
    static let shareSubtitle = "A private summary you choose where to post"
    static let shareFootnote = "Installed apps open first. The card and post text are copied so you can paste them if needed."

    static func menuDetail(_ stats: UsageStats, now: Date) -> String {
        guard stats.hasAny else { return "Words, speaking speed and streaks" }
        return "\(StatsFormat.count(stats.totalWords)) words · "
            + "\(StatsFormat.streak(stats.currentStreak(at: now))) streak"
    }
}

enum StatsFormat {
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func compactCount(_ value: Int) -> String {
        switch value {
        case ..<1_000:
            return count(value)
        case ..<1_000_000:
            return compact(Double(value) / 1_000, suffix: "K")
        default:
            return compact(Double(value) / 1_000_000, suffix: "M")
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m" }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    static func wordsPerMinute(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func streak(_ days: Int) -> String {
        "\(days) \(days == 1 ? "day" : "days")"
    }

    static func words(_ count: Int) -> String {
        "\(Self.count(count)) \(count == 1 ? "word" : "words")"
    }

    static func sessions(_ count: Int) -> String {
        "\(Self.count(count)) \(count == 1 ? "session" : "sessions")"
    }

    static func dayLabel(_ key: String, now: Date, timeZone: TimeZone = .current) -> String {
        let today = UsageStats.dayKey(now, timeZone: timeZone)
        guard let elapsed = UsageStats.daysBetween(key, today) else { return key }
        switch elapsed {
        case 0: return "Today"
        case 1: return "Yesterday"
        default:
            return formattedDay(key, format: "EEE, MMM d", timeZone: timeZone) ?? key
        }
    }

    static func shortDayLabel(_ key: String, timeZone: TimeZone = .current) -> String {
        formattedDay(key, format: "EEE", timeZone: timeZone) ?? "–"
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        let format = value < 10 && value.rounded() != value ? "%.1f%@" : "%.0f%@"
        return String(format: format, value, suffix)
    }

    private static func formattedDay(
        _ key: String,
        format: String,
        timeZone: TimeZone
    ) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: key) else { return nil }
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

enum StatsShareDestination: CaseIterable, Equatable, Sendable {
    case x
    case linkedIn

    var label: String { self == .x ? "X" : "LinkedIn" }

    var handle: String? { self == .x ? "@vocahq" : nil }
}

enum StatsShareTarget: Equatable, Sendable {
    case installedApp
    case browser
}

struct StatsShareRoute: Equatable, Sendable {
    let url: URL
    let target: StatsShareTarget
}

enum StatsShareComposer {
    static let site = "https://vocaphone.vocahq.com"

    static func message(
        _ stats: UsageStats,
        now: Date,
        destination: StatsShareDestination
    ) -> String {
        var details: [String] = []
        if stats.totalDictations > 0 {
            details.append("📊 \(pluralized(stats.totalDictations, "session"))")
        }
        if let duration = spokenDuration(stats.totalSeconds) {
            details.append("⏱️ \(duration) of talking")
        }
        if stats.averageWordsPerMinute > 0 {
            details.append("⚡️ \(Int(stats.averageWordsPerMinute.rounded())) WPM")
        }
        let streak = stats.currentStreak(at: now)
        if streak > 0 { details.append("🔥 \(streak)-day streak") }

        var lines = [
            "🎤 I’ve spoken \(pluralized(stats.totalWords, "word")) with VocaPhone.",
            details.joined(separator: " · "),
            "Private voice typing on my phone or my own self-hosted gateway. My audio stays mine. 🔒",
            [destination.handle, site].compactMap { $0 }.joined(separator: " · "),
        ]
        lines.removeAll(where: \.isEmpty)
        return lines.joined(separator: "\n\n")
    }

    static func pluralized(_ count: Int, _ noun: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        let value = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return "\(value) \(count == 1 ? noun : noun + "s")"
    }

    static func spokenDuration(_ seconds: Double) -> String? {
        let totalMinutes = max(0, Int(seconds) / 60)
        guard totalMinutes > 0 else { return nil }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        return parts.joined(separator: ", ")
    }

    static func composerURL(_ destination: StatsShareDestination, message: String) -> URL? {
        switch destination {
        case .x:
            guard var components = URLComponents(string: "https://x.com/intent/post") else {
                return nil
            }
            components.queryItems = [URLQueryItem(name: "text", value: message)]
            return components.url
        case .linkedIn:
            // Match VocaMac's feed composer: share-offsite accepts only a URL,
            // while this route carries the complete post body.
            guard var components = URLComponents(string: "https://www.linkedin.com/feed/") else {
                return nil
            }
            components.queryItems = [
                URLQueryItem(name: "shareActive", value: "true"),
                URLQueryItem(name: "text", value: message),
            ]
            return components.url
        }
    }

    static func nativeURL(_ destination: StatsShareDestination, message: String) -> URL? {
        switch destination {
        case .x:
            var components = URLComponents()
            // The renamed X app continues to register its long-standing
            // twitter scheme. The post route opens its native composer.
            components.scheme = "twitter"
            components.host = "post"
            components.queryItems = [URLQueryItem(name: "message", value: message)]
            return components.url
        case .linkedIn:
            // LinkedIn exposes no supported deep link for a prefilled post.
            // Open the installed app and put both the card and text on the
            // pasteboard; the browser fallback receives the full post body.
            return URL(string: "linkedin://")
        }
    }

    static func preferredRoute(
        _ destination: StatsShareDestination,
        message: String,
        canOpen: (URL) -> Bool
    ) -> StatsShareRoute? {
        if let native = nativeURL(destination, message: message), canOpen(native) {
            return StatsShareRoute(url: native, target: .installedApp)
        }
        guard let web = composerURL(destination, message: message) else { return nil }
        return StatsShareRoute(url: web, target: .browser)
    }
}
