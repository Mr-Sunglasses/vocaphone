import Foundation

enum SharedStoreError: Error {
    case appGroupUnavailable
    case unsupportedSchema(Int)
}

final class SharedStore: @unchecked Sendable {
    static let shared = SharedStore()

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

    func save(_ record: SessionRecord) throws {
        let directory = try sessionsDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(to: url(for: record.sessionID, directory: directory), options: .atomic)
        if record.state != .recording {
            try? fileManager.removeItem(at: meterURL(for: record.sessionID, directory: directory))
        }
    }

    func saveMeter(_ level: Float, for id: UUID) throws {
        let directory = try sessionsDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let clamped = min(max(level, 0), 1)
        let data = try encoder.encode(clamped)
        try data.write(to: meterURL(for: id, directory: directory), options: .atomic)
    }

    func load(_ id: UUID) throws -> SessionRecord? {
        let directory = try sessionsDirectory()
        let fileURL = url(for: id, directory: directory)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        var record = try decoder.decode(SessionRecord.self, from: Data(contentsOf: fileURL))
        guard record.schemaVersion == SessionRecord.schemaVersion else {
            throw SharedStoreError.unsupportedSchema(record.schemaVersion)
        }
        applyMeter(to: &record, directory: directory)
        return record
    }

    func recent(limit: Int = 20) throws -> [SessionRecord] {
        let directory = try sessionsDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { url -> SessionRecord? in
            var record = try decoder.decode(SessionRecord.self, from: Data(contentsOf: url))
            guard record.schemaVersion == SessionRecord.schemaVersion else { return nil }
            applyMeter(to: &record, directory: directory)
            return record
        }
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(limit)
        .map(\.self)
    }

    func saveQuickDictationAvailability(_ availability: QuickDictationAvailability) throws {
        let root = try rootDirectory()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try encoder.encode(availability)
        try data.write(to: quickDictationURL(root: root), options: .atomic)
    }

    func loadQuickDictationAvailability() throws -> QuickDictationAvailability? {
        let fileURL = quickDictationURL(root: try rootDirectory())
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let availability = try decoder.decode(
            QuickDictationAvailability.self,
            from: Data(contentsOf: fileURL)
        )
        guard availability.schemaVersion == QuickDictationAvailability.schemaVersion else {
            throw SharedStoreError.unsupportedSchema(availability.schemaVersion)
        }
        return availability
    }

    func clearQuickDictationAvailability() throws {
        let fileURL = quickDictationURL(root: try rootDirectory())
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func sessionsDirectory() throws -> URL {
        try rootDirectory().appendingPathComponent("sessions", isDirectory: true)
    }

    private func rootDirectory() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let groupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        ) else {
            throw SharedStoreError.appGroupUnavailable
        }
        return groupURL
    }

    private func url(for id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }

    private func meterURL(for id: UUID, directory: URL) -> URL {
        directory
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("meter")
    }

    private func quickDictationURL(root: URL) -> URL {
        root.appendingPathComponent("quick-dictation-availability.json")
    }

    private func applyMeter(to record: inout SessionRecord, directory: URL) {
        guard record.state == .recording else {
            record.meterLevel = 0
            return
        }
        let fileURL = meterURL(for: record.sessionID, directory: directory)
        guard let data = try? Data(contentsOf: fileURL),
              let level = try? decoder.decode(Float.self, from: data)
        else { return }
        record.meterLevel = min(max(level, 0), 1)
    }
}
