import Foundation

struct UsageStats: Codable, Equatable, Sendable {
    var totalWords: Int = 0
    var totalDictations: Int = 0
    var totalSeconds: Double = 0
    var lastDayKey: String = ""
    var currentStreak: Int = 0
    var bestStreak: Int = 0
    var dailyWords: [String: Int] = [:]
    var dailyDictations: [String: Int] = [:]
    var dailySeconds: [String: Double] = [:]

    static let dailyLimit = 7

    var hasAny: Bool { totalDictations > 0 }

    var averageWordsPerMinute: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalWords) / (totalSeconds / 60)
    }

    func currentStreak(at now: Date, timeZone: TimeZone = .current) -> Int {
        guard !lastDayKey.isEmpty else { return 0 }
        guard let elapsed = Self.daysBetween(lastDayKey, Self.dayKey(now, timeZone: timeZone)) else {
            return 0
        }
        if Self.isUnreconcilableFuture(elapsed) { return 0 }
        return elapsed <= 1 ? currentStreak : 0
    }

    func recording(dayKey key: String, words: Int, seconds: Double) -> UsageStats {
        guard words > 0 else { return self }
        var next = self
        next.totalWords += words
        next.totalDictations += 1
        next.totalSeconds += max(seconds, 0)
        var daily = dailyWords
        daily[key, default: 0] += words
        var dictations = dailyDictations
        dictations[key, default: 0] += 1
        var secondsByDay = dailySeconds
        secondsByDay[key, default: 0] += max(seconds, 0)
        let retained = Set(Self.rankedDayKeys(in: daily).prefix(Self.dailyLimit))
        next.dailyWords = daily.filter { retained.contains($0.key) }
        next.dailyDictations = dictations.filter { retained.contains($0.key) }
        next.dailySeconds = secondsByDay.filter { retained.contains($0.key) }
        let streak = Self.advanceStreak(currentStreak, lastDayKey: lastDayKey, todayKey: key)
        next.currentStreak = streak
        next.bestStreak = max(bestStreak, streak)
        next.lastDayKey = Self.nextDayKey(lastDayKey, todayKey: key)
        return next
    }

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        let parts = gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    static func daysBetween(_ fromKey: String, _ toKey: String) -> Int? {
        guard let from = epochDay(fromKey), let to = epochDay(toKey) else { return nil }
        return to - from
    }

    static func isDayKey(_ value: String) -> Bool { epochDay(value) != nil }

    private static func epochDay(_ key: String) -> Int? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard key.count == 10, parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return nil }
        let calendar = gregorian(TimeZone(secondsFromGMT: 0) ?? .current)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    static func advanceStreak(_ current: Int, lastDayKey: String, todayKey: String) -> Int {
        guard !lastDayKey.isEmpty else { return 1 }
        guard let elapsed = daysBetween(lastDayKey, todayKey) else { return 1 }
        if isUnreconcilableFuture(elapsed) { return 1 }
        if elapsed <= 0 { return max(current, 1) }
        if elapsed == 1 { return max(current, 0) + 1 }
        return 1
    }

    static func nextDayKey(_ stored: String, todayKey: String) -> String {
        guard isDayKey(stored) else { return todayKey }
        if let elapsed = daysBetween(stored, todayKey), isUnreconcilableFuture(elapsed) {
            return todayKey
        }
        return max(stored, todayKey)
    }

    private static func isUnreconcilableFuture(_ elapsed: Int) -> Bool {
        elapsed < -dailyLimit
    }

    static func pruneDaily(_ daily: [String: Int]) -> [String: Int] {
        guard daily.count > dailyLimit else { return daily }
        let ranked = rankedDayKeys(in: daily)
        return Dictionary(uniqueKeysWithValues: ranked.prefix(dailyLimit).map { ($0, daily[$0] ?? 0) })
    }

    private static func rankedDayKeys(in daily: [String: Int]) -> [String] {
        daily.keys.sorted { left, right in
            let leftReadable = isDayKey(left)
            let rightReadable = isDayKey(right)
            if leftReadable != rightReadable { return leftReadable }
            return left > right
        }
    }

    func recentDays(limit: Int = dailyLimit) -> [DailyUsage] {
        dailyWords
            .filter { Self.isDayKey($0.key) }
            .sorted { $0.key > $1.key }
            .prefix(limit)
            .map {
                DailyUsage(
                    key: $0.key,
                    words: $0.value,
                    dictations: dailyDictations[$0.key, default: 0],
                    seconds: dailySeconds[$0.key, default: 0]
                )
            }
    }

    /// Seven consecutive calendar days, including quiet days, for a chart that
    /// shows an actual trend rather than only the dates that have activity.
    func lastSevenDays(endingAt now: Date, timeZone: TimeZone = .current) -> [DailyUsage] {
        let calendar = Self.gregorian(timeZone)
        let today = calendar.startOfDay(for: now)
        return (0..<Self.dailyLimit).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let key = Self.dayKey(date, timeZone: timeZone)
            return DailyUsage(
                key: key,
                words: dailyWords[key, default: 0],
                dictations: dailyDictations[key, default: 0],
                seconds: dailySeconds[key, default: 0]
            )
        }
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }

    static func nextDayStart(after date: Date, timeZone: TimeZone = .current) -> Date {
        let calendar = gregorian(timeZone)
        let today = calendar.startOfDay(for: date)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return date.addingTimeInterval(86_400)
        }
        return calendar.startOfDay(for: tomorrow)
    }
}

struct DailyUsage: Equatable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let words: Int
    let dictations: Int
    let seconds: Double
}

extension UsageStats {
    /// New daily dimensions decode leniently so a build upgrade preserves a
    /// summary written before sessions and voice time were tracked per day.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalWords = try container.decodeIfPresent(Int.self, forKey: .totalWords) ?? 0
        totalDictations = try container.decodeIfPresent(Int.self, forKey: .totalDictations) ?? 0
        totalSeconds = try container.decodeIfPresent(Double.self, forKey: .totalSeconds) ?? 0
        lastDayKey = try container.decodeIfPresent(String.self, forKey: .lastDayKey) ?? ""
        currentStreak = try container.decodeIfPresent(Int.self, forKey: .currentStreak) ?? 0
        bestStreak = try container.decodeIfPresent(Int.self, forKey: .bestStreak) ?? 0
        dailyWords = try container.decodeIfPresent([String: Int].self, forKey: .dailyWords) ?? [:]
        dailyDictations = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .dailyDictations
        ) ?? [:]
        dailySeconds = try container.decodeIfPresent(
            [String: Double].self,
            forKey: .dailySeconds
        ) ?? [:]
    }
}
