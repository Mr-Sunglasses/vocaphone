import Foundation
import Testing

struct UsageStatsStoreTests {
    private func makeStore() throws -> (UsageStatsStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (UsageStatsStore(rootOverride: root), root)
    }

    private let utc = TimeZone(identifier: "UTC")!

    private func at(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func eventFiles(in root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("usage/events"),
            includingPropertiesForKeys: nil
        )) ?? []
    }

    @Test func nothingIsCountedBeforeAnythingIsDictated() throws {
        let (store, _) = try makeStore()
        #expect(!store.current().hasAny)
    }

    @Test func aRecordedDictationShowsUpBeforeItIsEverFolded() throws {
        let (store, _) = try makeStore()
        try store.record(transcript: "one two three", seconds: 6, now: at(2026, 9, 10), timeZone: utc)

        let stats = store.current()
        #expect(stats.totalWords == 3)
        #expect(stats.totalDictations == 1)
        #expect(stats.totalSeconds == 6)
    }

    @Test func foldingTurnsEventsIntoASummaryAndClearsTheFiles() throws {
        let (store, root) = try makeStore()
        try store.record(transcript: "one two", seconds: 4, now: at(2026, 9, 10), timeZone: utc)
        try store.record(transcript: "three four", seconds: 4, now: at(2026, 9, 10), timeZone: utc)

        let folded = try store.fold()
        #expect(folded.totalWords == 4)
        #expect(folded.totalDictations == 2)
        #expect(eventFiles(in: root).isEmpty, "folded events are removed")
        #expect(store.current().totalWords == 4, "and the summary carries them")
    }

    @Test func foldingIsIdempotent() throws {
        let (store, _) = try makeStore()
        try store.record(transcript: "one two three", seconds: 6, now: at(2026, 9, 10), timeZone: utc)
        _ = try store.fold()
        _ = try store.fold()
        #expect(store.current().totalWords == 3)
    }

    @Test func recordingTheSameSessionTwiceIsIdempotent() throws {
        let (store, _) = try makeStore()
        let sessionID = UUID()
        try store.record(
            transcript: "one two three",
            seconds: 6,
            id: sessionID,
            now: at(2026, 9, 10),
            timeZone: utc
        )
        try store.record(
            transcript: "one two three",
            seconds: 6,
            id: sessionID,
            now: at(2026, 9, 10),
            timeZone: utc
        )
        #expect(store.current().totalWords == 3)
        #expect(store.current().totalDictations == 1)
    }

    @Test func anInterruptedFoldDoesNotCountTwice() throws {
        let (store, root) = try makeStore()
        try store.record(transcript: "one two three", seconds: 6, now: at(2026, 9, 10), timeZone: utc)
        let files = eventFiles(in: root)
        let saved = try files.map { (url: $0, data: try Data(contentsOf: $0)) }

        _ = try store.fold()

        for file in saved { try file.data.write(to: file.url) }

        #expect(store.current().totalWords == 3, "the read path skips them")
        #expect(try store.fold().totalWords == 3, "and so does the next fold")
    }

    @Test func eventsFoldOldestDayFirstSoStreaksAreSequential() throws {
        let (store, _) = try makeStore()
        try store.record(transcript: "third day", seconds: 3, now: at(2026, 9, 12), timeZone: utc)
        try store.record(transcript: "first day", seconds: 3, now: at(2026, 9, 10), timeZone: utc)
        try store.record(transcript: "second day", seconds: 3, now: at(2026, 9, 11), timeZone: utc)

        let stats = try store.fold()
        #expect(stats.currentStreak == 3)
        #expect(stats.lastDayKey == "2026-09-12")
    }

    @Test func aSilentDictationIsNotRecordedAtAll() throws {
        let (store, root) = try makeStore()
        try store.record(transcript: "   ", seconds: 4, now: at(2026, 9, 10), timeZone: utc)
        #expect(eventFiles(in: root).isEmpty)
        #expect(!store.current().hasAny)
    }

    @Test func aDictationWithNoRecordedDurationStillCountsItsWords() throws {
        let (store, _) = try makeStore()
        try store.record(transcript: "one two", seconds: nil, now: at(2026, 9, 10), timeZone: utc)
        let stats = store.current()
        #expect(stats.totalWords == 2)
        #expect(stats.averageWordsPerMinute == 0, "no audio, no speed")
    }

    @Test func resettingRemovesTotalsAndPendingEventsAlike() throws {
        let (store, root) = try makeStore()
        try store.record(transcript: "one two", seconds: 4, now: at(2026, 9, 10), timeZone: utc)
        _ = try store.fold()
        try store.record(transcript: "three", seconds: 2, now: at(2026, 9, 10), timeZone: utc)

        try store.reset()
        #expect(!store.current().hasAny)
        #expect(eventFiles(in: root).isEmpty)
    }

    @Test func totalsSurviveDeletingEveryTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let usage = UsageStatsStore(rootOverride: root)
        let sessions = SharedStore(rootOverride: root)

        try sessions.save(SessionRecord(state: .idle))
        try usage.record(transcript: "one two three", seconds: 6, now: at(2026, 9, 10), timeZone: utc)
        _ = try usage.fold()

        _ = try sessions.deleteAllSessions()

        #expect(usage.current().totalWords == 3)
    }
}
