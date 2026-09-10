import Foundation

struct UsageEvent: Codable, Equatable, Sendable {
    let id: UUID
    let dayKey: String
    let words: Int
    let seconds: Double
}

private struct StoredSummary: Codable {
    var stats: UsageStats
    var consumedIDs: [UUID]
}

final class UsageStatsStore: @unchecked Sendable {
    static let shared = UsageStatsStore()

    private let fileManager: FileManager
    private let rootOverride: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    func record(
        transcript: String,
        seconds: Double?,
        id: UUID = UUID(),
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> UsageEvent? {
        let words = UsageStats.wordCount(transcript)
        guard words > 0 else { return nil }
        let event = UsageEvent(
            id: id,
            dayKey: UsageStats.dayKey(now, timeZone: timeZone),
            words: words,
            seconds: max(seconds ?? 0, 0)
        )
        let directory = try eventsDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(event)
        try data.write(to: directory.appendingPathComponent("\(event.id.uuidString).json"), options: .atomic)
        return event
    }

    @discardableResult
    func fold() throws -> UsageStats {
        var summary = loadSummary()
        let pending = try eventsOnDisk()
        guard !pending.isEmpty else { return summary.stats }

        let alreadyCounted = Set(summary.consumedIDs)
        let fresh = pending
            .filter { !alreadyCounted.contains($0.event.id) }
            .sorted { $0.event.dayKey < $1.event.dayKey }

        var stats = summary.stats
        for entry in fresh {
            stats = stats.recording(
                dayKey: entry.event.dayKey,
                words: entry.event.words,
                seconds: entry.event.seconds
            )
        }

        summary.stats = stats
        summary.consumedIDs = pending.map(\.event.id)
        try writeSummary(summary)

        for entry in pending {
            try? fileManager.removeItem(at: entry.url)
        }
        return stats
    }

    func current() -> UsageStats {
        let summary = loadSummary()
        guard let pending = try? eventsOnDisk(), !pending.isEmpty else { return summary.stats }
        let alreadyCounted = Set(summary.consumedIDs)
        var stats = summary.stats
        for entry in pending
            .filter({ !alreadyCounted.contains($0.event.id) })
            .sorted(by: { $0.event.dayKey < $1.event.dayKey }) {
            stats = stats.recording(
                dayKey: entry.event.dayKey,
                words: entry.event.words,
                seconds: entry.event.seconds
            )
        }
        return stats
    }

    func reset() throws {
        let directory = try usageDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }


    private func loadSummary() -> StoredSummary {
        guard let url = try? summaryURL(),
              let data = try? Data(contentsOf: url),
              let stored = try? decoder.decode(StoredSummary.self, from: data)
        else {
            return StoredSummary(stats: UsageStats(), consumedIDs: [])
        }
        return stored
    }

    private func writeSummary(_ summary: StoredSummary) throws {
        let directory = try usageDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(summary).write(to: try summaryURL(), options: .atomic)
    }

    private func eventsOnDisk() throws -> [(url: URL, event: UsageEvent)] {
        let directory = try eventsDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let event = try? decoder.decode(UsageEvent.self, from: data)
            else { return nil }
            return (url: url, event: event)
        }
    }

    private func summaryURL() throws -> URL {
        try usageDirectory().appendingPathComponent("summary.json")
    }

    private func eventsDirectory() throws -> URL {
        try usageDirectory().appendingPathComponent("events", isDirectory: true)
    }

    private func usageDirectory() throws -> URL {
        let root = try rootOverride ?? SharedStore.shared.rootDirectory()
        return root.appendingPathComponent("usage", isDirectory: true)
    }
}
