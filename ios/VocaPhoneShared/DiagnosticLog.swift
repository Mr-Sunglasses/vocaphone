import Foundation

enum DiagnosticSource: String, Codable, Sendable {
    case app
    case keyboard
    case liveActivity
    case tests

    static var current: DiagnosticSource {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        if identifier.hasSuffix(".keyboard") { return .keyboard }
        if identifier.hasSuffix(".liveactivity") { return .liveActivity }
        if identifier.contains("Tests") || identifier.contains("tests") { return .tests }
        return .app
    }
}

/// Deliberately finite and content-free. There is no API here that accepts a
/// transcript, typed text, audio path, URL, token, microphone name, or arbitrary
/// metadata, so private user content cannot accidentally enter an export.
enum DiagnosticEvent: String, Codable, Sendable {
    case appStarted
    case keyboardShown
    case sessionStateChanged
    case quickDictationArmed
    case quickDictationStopped
    case quickDictationStale
    case stopQuickDictationRequested
    case audioInterruptionBegan
    case audioInterruptionEnded
    case audioMediaServicesReset
    case audioInputUnavailable
    case liveActivityStarted
    case liveActivityEnded
    case finishRequested
    case captureStopped
    case streamHandshakeStarted
    case streamReady
    case batchFallback
    case uploadStarted
    case uploadCompleted
    case transcriptionStarted
    case transcriptReady
    case insertionStarted
    case insertionCompleted
    case operationFailed
}

enum DiagnosticReason: String, Codable, Sendable {
    case userRequested
    case quickDictationOff
    case sessionFinished
    case processExit
    case resumeAllowed
    case resumeNotAllowed
}

enum DiagnosticPhase: String, Codable, Sendable {
    case standby
    case recording
}

enum DiagnosticErrorCode: String, Codable, Sendable {
    case audioMissing
    case diagnosticExportFailed
    case gatewayNotConfigured
    case languageUnsupported
    case microphonePermissionDenied
    case quickDictationArmFailed
    case recordingStartFailed
    case serverUnavailable
    case transcriptionFailed
    case uploadFailed
}

struct DiagnosticMetadata: Codable, Equatable, Sendable {
    let state: SessionState?
    let reason: DiagnosticReason?
    let phase: DiagnosticPhase?
    let errorCode: DiagnosticErrorCode?
    let hasFullAccess: Bool?

    static let empty = DiagnosticMetadata()

    private init(
        state: SessionState? = nil,
        reason: DiagnosticReason? = nil,
        phase: DiagnosticPhase? = nil,
        errorCode: DiagnosticErrorCode? = nil,
        hasFullAccess: Bool? = nil
    ) {
        self.state = state
        self.reason = reason
        self.phase = phase
        self.errorCode = errorCode
        self.hasFullAccess = hasFullAccess
    }

    static func state(_ state: SessionState) -> DiagnosticMetadata {
        DiagnosticMetadata(state: state)
    }

    static func reason(_ reason: DiagnosticReason) -> DiagnosticMetadata {
        DiagnosticMetadata(reason: reason)
    }

    static func phase(_ phase: DiagnosticPhase) -> DiagnosticMetadata {
        DiagnosticMetadata(phase: phase)
    }

    static func error(_ errorCode: DiagnosticErrorCode) -> DiagnosticMetadata {
        DiagnosticMetadata(errorCode: errorCode)
    }

    static func fullAccess(_ hasFullAccess: Bool) -> DiagnosticMetadata {
        DiagnosticMetadata(hasFullAccess: hasFullAccess)
    }
}

struct DiagnosticEntry: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let timestamp: Date
    /// Monotonic across processes for one device boot, with enough resolution
    /// to distinguish notification, capture, upload and insertion delays.
    /// Optional so diagnostics written by earlier builds still decode.
    let uptimeMilliseconds: UInt64?
    let source: DiagnosticSource
    let event: DiagnosticEvent
    let metadata: DiagnosticMetadata
    let appVersion: String
    let buildNumber: String

    init(
        timestamp: Date = Date(),
        uptimeMilliseconds: UInt64? = nil,
        source: DiagnosticSource,
        event: DiagnosticEvent,
        metadata: DiagnosticMetadata = .empty
    ) {
        schemaVersion = Self.schemaVersion
        self.timestamp = timestamp
        self.uptimeMilliseconds = uptimeMilliseconds ?? UInt64(
            (ProcessInfo.processInfo.systemUptime * 1_000).rounded()
        )
        self.source = source
        self.event = event
        self.metadata = metadata
        appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        buildNumber = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
    }
}

enum DiagnosticLog {
    static let maximumFileSize = 200_000
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    private static let fileName = "vocaphone-diagnostics.ndjson"
    private static let lock = NSLock()
    private static let writeQueue = DispatchQueue(
        label: "com.vocahq.vocaphone.diagnostics",
        qos: .utility
    )

    static func record(
        _ event: DiagnosticEvent,
        source: DiagnosticSource = .current,
        metadata: DiagnosticMetadata = .empty
    ) {
        guard let fileURL else { return }
        let entry = DiagnosticEntry(source: source, event: event, metadata: metadata)
        writeQueue.async {
            append(entry, to: fileURL)
        }
    }

    static func read() -> String {
        guard let fileURL else { return "" }
        return writeQueue.sync { coordinatedRead(from: fileURL) }
    }

    static func clear() {
        guard let fileURL else { return }
        writeQueue.sync { coordinatedWrite(Data(), to: fileURL) }
    }

    static func makeExportFile(now: Date = Date()) throws -> URL {
        let entries = retainedEntries(from: read(), now: now)
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        let header = """
        VocaPhone diagnostics
        App: \(version) (\(build))
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Privacy: state and lifecycle metadata only; no transcript, typed text, audio, or credentials.
        ---

        """
        let body = entries.joined(separator: "\n")
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocaphone-diagnostics-\(Int(now.timeIntervalSince1970)).txt")
        try Data((header + body + (body.isEmpty ? "" : "\n")).utf8)
            .write(to: exportURL, options: .atomic)
        return exportURL
    }

    /// Internal entry point used by tests with an isolated temporary file.
    static func append(_ entry: DiagnosticEntry, to fileURL: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedURL in
            if !FileManager.default.fileExists(atPath: coordinatedURL.path) {
                FileManager.default.createFile(atPath: coordinatedURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: coordinatedURL) else { return }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } catch {
                try? handle.close()
                return
            }
            trimIfNeeded(coordinatedURL)
        }
    }

    static func retainedEntries(from contents: String, now: Date) -> [String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return contents.split(separator: "\n").compactMap { line in
            guard let entry = try? decoder.decode(DiagnosticEntry.self, from: Data(line.utf8)),
                  now.timeIntervalSince(entry.timestamp) <= retentionInterval
            else { return nil }
            return String(line)
        }
    }

    private static var fileURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        )?.appendingPathComponent(fileName)
    }

    private static func coordinatedRead(from fileURL: URL) -> String {
        lock.lock()
        defer { lock.unlock() }
        var result = ""
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) {
            coordinatedURL in
            result = (try? String(contentsOf: coordinatedURL, encoding: .utf8)) ?? ""
        }
        return result
    }

    private static func coordinatedWrite(_ data: Data, to fileURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            try? data.write(to: coordinatedURL, options: .atomic)
        }
    }

    private static func trimIfNeeded(_ fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL),
              data.count > maximumFileSize
        else { return }

        let suffix = data.suffix(maximumFileSize)
        guard let newline = suffix.firstIndex(of: 0x0A) else {
            try? Data(suffix).write(to: fileURL, options: .atomic)
            return
        }
        let start = suffix.index(after: newline)
        try? Data(suffix[start...]).write(to: fileURL, options: .atomic)
    }
}
