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
        return try sessionFilesByRecency(in: directory)
            .prefix(limit)
            .compactMap { url -> SessionRecord? in
                guard var record = decodedRecord(at: url) else { return nil }
                applyMeter(to: &record, directory: directory)
                return record
            }
    }

    /// Returns the newest session without decoding the whole directory. The
    /// keyboard extension calls this from its main thread, so the cost has to
    /// stay flat as sessions accumulate rather than growing with the archive.
    func mostRecent() throws -> SessionRecord? {
        let directory = try sessionsDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        for url in try sessionFilesByRecency(in: directory) {
            guard var record = decodedRecord(at: url) else { continue }
            applyMeter(to: &record, directory: directory)
            return record
        }
        return nil
    }

    /// Session records otherwise live in the shared container for the life of
    /// the install. Bounding the archive keeps lookups cheap and the extension's
    /// disk footprint predictable.
    @discardableResult
    func pruneSessions(
        keeping keepCount: Int = 50,
        terminalOlderThan maximumAge: TimeInterval = 7 * 24 * 60 * 60,
        now: Date = Date()
    ) throws -> Int {
        let directory = try sessionsDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        var removed = 0
        for (index, url) in try sessionFilesByRecency(in: directory).enumerated() {
            let isBeyondWindow = index >= keepCount
            let isStaleTerminal = !isBeyondWindow && decodedRecord(at: url).map {
                $0.state.isTerminal && now.timeIntervalSince($0.updatedAt) > maximumAge
            } == true
            guard isBeyondWindow || isStaleTerminal else { continue }
            try? fileManager.removeItem(at: url)
            try? fileManager.removeItem(
                at: url.deletingPathExtension().appendingPathExtension("meter")
            )
            removed += 1
        }
        return removed
    }

    /// Audio is deleted as soon as a transcript arrives, but a crash between
    /// upload and cleanup can strand a recording. Drop files no live session
    /// still references; the age floor protects a capture that is mid-flight and
    /// has not been written into its record yet.
    @discardableResult
    func pruneOrphanedAudio(
        minimumAge: TimeInterval = 60 * 60,
        now: Date = Date()
    ) throws -> Int {
        let directory = try rootDirectory()
            .appendingPathComponent("pending-audio", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        let referenced = Set(
            try recent(limit: 200)
                .filter { !$0.state.isTerminal }
                .compactMap(\.localAudioReference)
        )
        var removed = 0
        for url in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            guard !referenced.contains(url.lastPathComponent),
                  now.timeIntervalSince(modificationDate(of: url)) > minimumAge
            else { continue }
            try? fileManager.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    private func sessionFilesByRecency(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        .filter { $0.pathExtension == "json" }
        .map { ($0, modificationDate(of: $0)) }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private func decodedRecord(at url: URL) -> SessionRecord? {
        guard let data = try? Data(contentsOf: url),
              let record = try? decoder.decode(SessionRecord.self, from: data),
              record.schemaVersion == SessionRecord.schemaVersion
        else { return nil }
        return record
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
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

    func saveKeyboardStatus(_ status: KeyboardStatus) throws {
        let root = try rootDirectory()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try encoder.encode(status)
        try data.write(to: keyboardStatusURL(root: root), options: .atomic)
    }

    func loadKeyboardStatus() throws -> KeyboardStatus? {
        let fileURL = keyboardStatusURL(root: try rootDirectory())
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let status = try decoder.decode(KeyboardStatus.self, from: Data(contentsOf: fileURL))
        guard status.schemaVersion == KeyboardStatus.schemaVersion else {
            throw SharedStoreError.unsupportedSchema(status.schemaVersion)
        }
        return status
    }

    private func keyboardStatusURL(root: URL) -> URL {
        root.appendingPathComponent("keyboard-status.json")
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
