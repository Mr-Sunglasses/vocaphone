import Foundation
import Testing

struct UsageStatsTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, zone: TimeZone? = nil) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }


    @Test func aDayKeyIsTheLocalCalendarDate() {
        #expect(UsageStats.dayKey(at(2026, 9, 10), timeZone: utc) == "2026-09-10")
    }

    @Test func dayKeysAreGregorianWhateverTheDeviceCalendarIs() {
        #expect(UsageStats.dayKey(at(2026, 9, 10), timeZone: utc).hasPrefix("2026-"))
    }

    @Test func onlyRealDatesAreReadableAsDays() {
        #expect(UsageStats.isDayKey("2026-09-10"))
        #expect(!UsageStats.isDayKey(""))
        #expect(!UsageStats.isDayKey("not-a-date"))
        #expect(!UsageStats.isDayKey("2026-9-10"))
        #expect(!UsageStats.isDayKey("2026-02-31"), "well-shaped but impossible")
    }

    @Test func daysBetweenCountsCalendarDaysNotHours() {
        #expect(UsageStats.daysBetween("2026-09-09", "2026-09-10") == 1)
        #expect(UsageStats.daysBetween("2026-09-10", "2026-09-09") == -1)
        #expect(UsageStats.daysBetween("2026-02-28", "2026-03-01") == 1)
        #expect(UsageStats.daysBetween("nonsense", "2026-09-10") == nil)
    }


    @Test func consecutiveDaysExtendTheRunAndAGapResetsIt() {
        var stats = UsageStats()
        stats = stats.recording(dayKey: "2026-09-08", words: 10, seconds: 5)
        #expect(stats.currentStreak == 1)
        stats = stats.recording(dayKey: "2026-09-09", words: 10, seconds: 5)
        #expect(stats.currentStreak == 2)
        stats = stats.recording(dayKey: "2026-09-11", words: 10, seconds: 5)
        #expect(stats.currentStreak == 1, "a day was missed")
        #expect(stats.bestStreak == 2, "the best run survives the reset")
    }

    @Test func twoDictationsOnOneDayAreOneStreakDay() {
        var stats = UsageStats().recording(dayKey: "2026-09-10", words: 5, seconds: 2)
        stats = stats.recording(dayKey: "2026-09-10", words: 5, seconds: 2)
        #expect(stats.currentStreak == 1)
        #expect(stats.totalDictations == 2)
        #expect(stats.dailyWords["2026-09-10"] == 10)
        #expect(stats.dailyDictations["2026-09-10"] == 2)
        #expect(stats.dailySeconds["2026-09-10"] == 4)
    }

    @Test func sevenDayActivityIncludesQuietCalendarDays() {
        let stats = UsageStats().recording(dayKey: "2026-09-10", words: 5, seconds: 3)
        let days = stats.lastSevenDays(endingAt: at(2026, 9, 10), timeZone: utc)
        #expect(days.count == 7)
        #expect(days.last?.key == "2026-09-10")
        #expect(days.last?.words == 5)
        #expect(days.last?.dictations == 1)
        #expect(days.dropLast().allSatisfy { $0.words == 0 && $0.dictations == 0 })
    }

    @Test func aStreakExpiresWhenReadRatherThanWhenWritten() {
        let stats = UsageStats(
            totalWords: 50,
            totalDictations: 5,
            lastDayKey: "2026-09-10",
            currentStreak: 5,
            bestStreak: 5
        )
        #expect(stats.currentStreak(at: at(2026, 9, 10), timeZone: utc) == 5, "same day")
        #expect(stats.currentStreak(at: at(2026, 9, 11), timeZone: utc) == 5, "yesterday, still savable")
        #expect(stats.currentStreak(at: at(2026, 9, 12), timeZone: utc) == 0, "a day was missed")
        #expect(stats.currentStreak(at: at(2026, 12, 25), timeZone: utc) == 0)
    }

    @Test func aStreakThatNeverStartedIsZero() {
        #expect(UsageStats().currentStreak(at: at(2026, 9, 10), timeZone: utc) == 0)
    }

    @Test func aFutureDatedDayDoesNotFreezeTheRunForever() {
        let stats = UsageStats(lastDayKey: "2099-01-01", currentStreak: 4, bestStreak: 4)
        #expect(stats.currentStreak(at: at(2026, 9, 10), timeZone: utc) == 0)
        #expect(UsageStats.nextDayKey("2099-01-01", todayKey: "2026-09-10") == "2026-09-10")
    }

    @Test func aClockNudgedBackwardsKeepsTheRun() {
        let stats = UsageStats(lastDayKey: "2026-09-11", currentStreak: 3, bestStreak: 3)
        #expect(stats.currentStreak(at: at(2026, 9, 10), timeZone: utc) == 3)
    }

    @Test func anUnreadableStoredDayIsRepairedRatherThanKept() {
        #expect(UsageStats.nextDayKey("not-a-date", todayKey: "2026-09-10") == "2026-09-10")
        let stats = UsageStats(lastDayKey: "not-a-date", currentStreak: 3)
        #expect(stats.currentStreak(at: at(2026, 9, 10), timeZone: utc) == 0)
    }

    @Test func onlyTheSevenMostRecentDaysAreKept() {
        var daily: [String: Int] = [:]
        for day in 1...10 { daily[String(format: "2026-09-%02d", day)] = day }
        let pruned = UsageStats.pruneDaily(daily)
        #expect(pruned.count == 7)
        #expect(pruned["2026-09-10"] == 10)
        #expect(pruned["2026-09-03"] == nil, "the oldest went first")
    }

    @Test func anUnreadableLabelDoesNotEvictARealDay() {
        var daily: [String: Int] = ["zzz-not-a-day": 99]
        for day in 1...7 { daily[String(format: "2026-09-%02d", day)] = day }
        let pruned = UsageStats.pruneDaily(daily)
        #expect(pruned["zzz-not-a-day"] == nil)
        #expect(pruned.count == 7)
        #expect(pruned["2026-09-01"] == 1, "the real days all survived")
    }

    @Test func wordsAreCountedBySegmentationNotSpaces() {
        #expect(UsageStats.wordCount("Meet me by the station at six") == 7)
        #expect(UsageStats.wordCount("  ") == 0)
        #expect(UsageStats.wordCount("") == 0)
        #expect(UsageStats.wordCount("well-known") >= 1)
    }

    @Test func aDictationWithNoWordsChangesNothing() {
        let stats = UsageStats().recording(dayKey: "2026-09-10", words: 0, seconds: 4)
        #expect(!stats.hasAny)
        #expect(stats.totalSeconds == 0)
    }

    @Test func speakingSpeedIsWordsOverRecordedMinutes() {
        let stats = UsageStats(totalWords: 120, totalDictations: 2, totalSeconds: 60)
        #expect(stats.averageWordsPerMinute == 120)
    }

    @Test func speakingSpeedIsZeroRatherThanInfiniteWithoutAudio() {
        #expect(UsageStats(totalWords: 10).averageWordsPerMinute == 0)
    }

    @Test func theNextDayStartsAtTheNextLocalMidnight() {
        let start = UsageStats.nextDayStart(after: at(2026, 9, 10, hour: 12), timeZone: utc)
        #expect(start == at(2026, 9, 11, hour: 0))
    }

    @Test func theDayTheClocksChangeIsShorterOrLonger() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let spring = at(2026, 3, 8, hour: 0, zone: la)
        let fall = at(2026, 11, 1, hour: 0, zone: la)
        #expect(UsageStats.nextDayStart(after: spring, timeZone: la).timeIntervalSince(spring) == 23 * 3_600)
        #expect(UsageStats.nextDayStart(after: fall, timeZone: la).timeIntervalSince(fall) == 25 * 3_600)
    }

    @Test func anAmbiguousMidnightIsTheFirstOneNotTheSecond() {
        let havana = TimeZone(identifier: "America/Havana")!
        let noon = at(2026, 10, 31, hour: 12, zone: havana)
        #expect(UsageStats.nextDayStart(after: noon, timeZone: havana).timeIntervalSince(noon) == 12 * 3_600)
    }

    @Test func theNextDayStartIsExactlyTheBoundaryInEveryZone() {
        let zones = ["UTC", "America/Los_Angeles", "Asia/Kolkata", "America/Havana",
                     "Atlantic/Azores", "Australia/Lord_Howe", "Asia/Kathmandu"]
        for id in zones {
            let zone = TimeZone(identifier: id)!
            var moment = at(2026, 1, 1, hour: 0)
            while moment < at(2026, 12, 31, hour: 0) {
                let start = UsageStats.nextDayStart(after: moment, timeZone: zone)
                let today = UsageStats.dayKey(moment, timeZone: zone)
                #expect(start > moment, "\(id) did not move forward at \(today)")
                #expect(
                    UsageStats.dayKey(start, timeZone: zone) != today,
                    "\(id) did not reach the next day at \(today)"
                )
                #expect(
                    UsageStats.dayKey(start.addingTimeInterval(-1), timeZone: zone) == today,
                    "\(id) overshot the boundary at \(today)"
                )
                moment = moment.addingTimeInterval(3_600 + 37)
            }
        }
    }

    @Test func aStoredSummaryRoundTrips() throws {
        let stats = UsageStats(
            totalWords: 900,
            totalDictations: 31,
            totalSeconds: 412.5,
            lastDayKey: "2026-09-10",
            currentStreak: 4,
            bestStreak: 9,
            dailyWords: ["2026-09-10": 120]
        )
        let data = try JSONEncoder().encode(stats)
        #expect(try JSONDecoder().decode(UsageStats.self, from: data) == stats)
    }

    @Test func anOlderSummaryWithoutDailyDimensionsStillDecodes() throws {
        let data = Data(
            #"{"totalWords":3,"totalDictations":1,"dailyWords":{"2026-09-10":3}}"#.utf8
        )
        let stats = try JSONDecoder().decode(UsageStats.self, from: data)
        #expect(stats.totalWords == 3)
        #expect(stats.dailyDictations.isEmpty)
        #expect(stats.dailySeconds.isEmpty)
    }
}
