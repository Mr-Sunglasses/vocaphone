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
    case sessionExpired
    case quickDictationArmed
    case quickDictationStopped
    case quickDictationStale
    /// The loaded speech model was dropped, with how much room that left.
    case localEngineReleased
    /// An on-device engine finished building, with how long it took, whether
    /// the app was in front, and the headroom left. A cold load in the
    /// background is the usual story behind a first dictation that fails and a
    /// second one that works, and this line is what tells the two apart.
    case localEngineLoaded
    /// A load or decode failed and is being tried once more on a fresh engine.
    /// The failure itself is the `operationFailed` line just before it.
    case localEngineRetried
    /// A Whisper window that sounded like speech decoded to no text. Nothing
    /// failed and the rest of the transcript went in, so without this line a
    /// dictation missing half its words looks like one that worked.
    case localWindowEmpty
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
    /// Automatic insertion was declined, with the reason. A transcript that
    /// silently fails to appear is the hardest thing in this product to report
    /// and the hardest to reproduce: it depends on whether iOS kept the
    /// keyboard extension alive and on whether the host app kept the same
    /// document identifier. Without this line there is nothing to look at.
    case insertionSkipped
    case operationFailed
}

enum DiagnosticReason: String, Codable, Sendable {
    case userRequested
    /// Quick Dictation was stopped from the Live Activity, which pauses the
    /// current window instead of changing the durable preference.
    case pausedUntilRelaunch
    /// VocaPhone was switched off from the keyboard: the running window ended
    /// as if the app had been closed, with every preference left alone.
    case closedFromKeyboard
    case quickDictationOff
    case sessionFinished
    case processExit
    /// A Live Activity outlived the process that created it — a jetsam kill or
    /// a crash mid-recording — and was cleared on the next launch.
    case orphanRecovered
    case resumeAllowed
    case resumeNotAllowed
    /// The field the cursor is in is not the field the transcript was dictated
    /// for, so the session parked itself instead of inserting.
    case targetFieldChanged
    /// The transcript came back empty — everything in it was a model
    /// annotation, or the sanitizer had nothing left after cleaning it.
    case transcriptEmpty
    /// An insertion was already running. Re-entrancy, not a failure: the text
    /// is going in from the first call.
    case insertionInFlight
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
    case localModelCleanupFailed
    /// The on-device engine could not be built from files already on disk.
    case localEngineLoadFailed
    /// The engine was built and then failed while decoding.
    case localDecodeFailed
    case microphonePermissionDenied
    /// Recording succeeded but another app held the input, so it captured only
    /// silence. Distinct from a permission problem, which the user fixes once.
    case microphoneSilenced
    case quickDictationArmFailed
    case recordingStartFailed
    case serverUnavailable
    case transcriptionFailed
    case uploadFailed
}

/// Which framework an error came from, reduced to a closed set. The domain
/// string itself is not recorded: it is the framework's own, but keeping the
/// field an enum is what keeps the log free of any text it did not choose.
enum DiagnosticErrorDomain: String, Codable, Sendable {
    case coreML
    case whisperKit
    /// A sherpa-onnx native status, from the bridge rather than an `Error`.
    case sherpa
    case localModel
    case audio
    case cocoa
    case posix
    case osStatus
    case mach
    case cancellation
    case other

    init(_ error: Error) {
        let domain = (error as NSError).domain
        switch domain {
        case "com.apple.CoreML": self = .coreML
        case "com.apple.coreaudio.avfaudio": self = .audio
        case NSCocoaErrorDomain: self = .cocoa
        case NSPOSIXErrorDomain: self = .posix
        case NSOSStatusErrorDomain: self = .osStatus
        case NSMachErrorDomain: self = .mach
        default:
            // A Swift error bridges with its type's qualified name as the domain.
            if error is CancellationError {
                self = .cancellation
            } else if domain.hasPrefix("WhisperKit.") {
                self = .whisperKit
            } else if domain.hasSuffix(".LocalModelManagerError") {
                self = .localModel
            } else {
                self = .other
            }
        }
    }
}

struct DiagnosticMetadata: Codable, Equatable, Sendable {
    let state: SessionState?
    let reason: DiagnosticReason?
    let phase: DiagnosticPhase?
    let errorCode: DiagnosticErrorCode?
    let hasFullAccess: Bool?
    /// Whole megabytes of headroom the process had left. A count and nothing
    /// else — a keyboard extension is killed for exceeding its budget, and
    /// without this number the only symptom is a keyboard that will not open.
    let megabytesAvailable: Int?
    /// Where an error came from and its numeric code — the outermost error and,
    /// when Core ML wraps the real cause, the innermost one it carries. Numbers
    /// and a closed domain only; an error's message is never recorded.
    let errorDomain: DiagnosticErrorDomain?
    let errorNumber: Int?
    let underlyingErrorDomain: DiagnosticErrorDomain?
    let underlyingErrorNumber: Int?
    /// Whether the containing app was on screen. iOS treats a backgrounded app
    /// very differently — suspension, no GPU — and a failure reads differently
    /// once you know which side of that it happened on.
    let appInForeground: Bool?
    /// A duration, in whole milliseconds.
    let milliseconds: Int?
    /// Which decoding window of how many, counted from zero.
    let windowIndex: Int?
    let windowCount: Int?

    static let empty = DiagnosticMetadata()

    private init(
        state: SessionState? = nil,
        reason: DiagnosticReason? = nil,
        phase: DiagnosticPhase? = nil,
        errorCode: DiagnosticErrorCode? = nil,
        hasFullAccess: Bool? = nil,
        megabytesAvailable: Int? = nil,
        errorDomain: DiagnosticErrorDomain? = nil,
        errorNumber: Int? = nil,
        underlyingErrorDomain: DiagnosticErrorDomain? = nil,
        underlyingErrorNumber: Int? = nil,
        appInForeground: Bool? = nil,
        milliseconds: Int? = nil,
        windowIndex: Int? = nil,
        windowCount: Int? = nil
    ) {
        self.state = state
        self.reason = reason
        self.phase = phase
        self.errorCode = errorCode
        self.hasFullAccess = hasFullAccess
        self.megabytesAvailable = megabytesAvailable
        self.errorDomain = errorDomain
        self.errorNumber = errorNumber
        self.underlyingErrorDomain = underlyingErrorDomain
        self.underlyingErrorNumber = underlyingErrorNumber
        self.appInForeground = appInForeground
        self.milliseconds = milliseconds
        self.windowIndex = windowIndex
        self.windowCount = windowCount
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

    static func megabytesAvailable(_ megabytes: Int) -> DiagnosticMetadata {
        DiagnosticMetadata(megabytesAvailable: megabytes)
    }

    /// An on-device engine failure, with the error reduced to numbers.
    static func localEngineFailure(
        _ errorCode: DiagnosticErrorCode,
        underlying error: Error,
        appInForeground: Bool,
        megabytesAvailable: Int
    ) -> DiagnosticMetadata {
        let outer = error as NSError
        var innermost = outer
        // Bounded: a cyclic chain is not expected, but it must not hang a log line.
        for _ in 0..<8 {
            guard let next = innermost.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            innermost = next
        }
        let hasUnderlying = innermost !== outer
        return DiagnosticMetadata(
            errorCode: errorCode,
            megabytesAvailable: megabytesAvailable,
            errorDomain: DiagnosticErrorDomain(error),
            errorNumber: outer.code,
            underlyingErrorDomain: hasUnderlying ? DiagnosticErrorDomain(innermost) : nil,
            underlyingErrorNumber: hasUnderlying ? innermost.code : nil,
            appInForeground: appInForeground
        )
    }

    /// A sherpa decode that failed natively. The bridge returns a status, not an
    /// `Error`, so the status itself is the number; one it does not name has none.
    static func sherpaDecodeFailure(
        _ failure: SherpaNativeFailure,
        appInForeground: Bool,
        megabytesAvailable: Int
    ) -> DiagnosticMetadata {
        DiagnosticMetadata(
            errorCode: .localDecodeFailed,
            megabytesAvailable: megabytesAvailable,
            errorDomain: .sherpa,
            errorNumber: failure.status.map(Int.init),
            appInForeground: appInForeground
        )
    }

    static func emptyWindow(index: Int, count: Int, milliseconds: Int) -> DiagnosticMetadata {
        DiagnosticMetadata(milliseconds: milliseconds, windowIndex: index, windowCount: count)
    }

    static func localEngineLoaded(
        milliseconds: Int,
        appInForeground: Bool,
        megabytesAvailable: Int
    ) -> DiagnosticMetadata {
        DiagnosticMetadata(
            megabytesAvailable: megabytesAvailable,
            appInForeground: appInForeground,
            milliseconds: milliseconds
        )
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

#if DEBUG
    /// The keyboard's touch and frame trace, alongside this log.
    ///
    /// Written by the extension into the App Group, which `devicectl` will not
    /// transfer; the app's Documents directory it will.
    static func mirrorKeyboardTraceForDeviceTransfer() {
        guard let group = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
              ),
              let documents = FileManager.default.urls(
                  for: .documentDirectory,
                  in: .userDomainMask
              ).first
        else { return }
        let source = group.appendingPathComponent("touch-trace.txt")
        let destination = documents.appendingPathComponent("touch-trace-latest.txt")
        writeQueue.async {
            guard let data = try? Data(contentsOf: source) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }

    /// Copies the log where a Mac can fetch it with `devicectl`.
    ///
    /// The log itself lives at the root of the App Group container, and
    /// `devicectl` refuses to transfer anything there — it lists only
    /// `Library/` and answers a root path with "File paths cannot contain
    /// '..'". The app's own Documents directory it will hand over, so a debug
    /// build leaves a copy there and the diagnosing loop stops depending on the
    /// user exporting and pasting a file the clipboard expires in minutes.
    static func mirrorForDeviceTransfer() {
        guard let fileURL,
              let documents = FileManager.default.urls(
                  for: .documentDirectory,
                  in: .userDomainMask
              ).first
        else { return }
        let destination = documents.appendingPathComponent("diagnostics-latest.ndjson")
        writeQueue.async {
            guard let data = try? Data(contentsOf: fileURL) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }
#endif

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
        let latency = DiagnosticLatency.reportLines(decodedEntries(entries))
        let latencyBlock = latency.isEmpty
            ? ""
            : "Latency:\n" + latency.map { "  \($0)\n" }.joined()
        let header = """
        VocaPhone diagnostics
        App: \(version) (\(build))
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Privacy: state and lifecycle metadata only; no transcript, typed text, audio, or credentials.
        \(latencyBlock)---

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

    static func decodedEntries(_ lines: [String]) -> [DiagnosticEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return lines.compactMap { try? decoder.decode(DiagnosticEntry.self, from: Data($0.utf8)) }
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
