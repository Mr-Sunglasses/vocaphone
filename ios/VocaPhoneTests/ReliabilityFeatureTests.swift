import Foundation
import Testing

struct ReliabilityFeatureTests {
    @Test func multipleDarwinObserversReceiveTheSameSignal() {
        let semaphore = DispatchSemaphore(value: 0)
        let callbackQueue = DispatchQueue(
            label: "com.vocahq.vocaphone.tests.darwin",
            attributes: .concurrent
        )
        let first = VocaPhoneDarwinCenter.observe(
            .quickDictationChanged,
            queue: callbackQueue
        ) {
            semaphore.signal()
        }
        let second = VocaPhoneDarwinCenter.observe(
            .quickDictationChanged,
            queue: callbackQueue
        ) {
            semaphore.signal()
        }
        defer {
            first.invalidate()
            second.invalidate()
        }

        VocaPhoneDarwinCenter.post(.quickDictationChanged)
        #expect(semaphore.wait(timeout: .now() + 1) == .success)
        #expect(semaphore.wait(timeout: .now() + 1) == .success)
    }

    @Test func quickDictationRequiresAFreshHeartbeat() {
        let now = Date(timeIntervalSince1970: 10_000)
        let availability = QuickDictationAvailability(
            activatedAt: now,
            expiresAt: now.addingTimeInterval(600),
            heartbeatAt: now
        )

        #expect(availability.isReady(at: now.addingTimeInterval(5)))
        #expect(!availability.isReady(at: now.addingTimeInterval(7)))
    }

    @Test func refreshingHeartbeatPreservesTheStandbyWindow() {
        let started = Date(timeIntervalSince1970: 10_000)
        let expires = started.addingTimeInterval(600)
        let refreshedAt = started.addingTimeInterval(4)
        let availability = QuickDictationAvailability(
            activatedAt: started,
            expiresAt: expires
        ).refreshingHeartbeat(at: refreshedAt)

        #expect(availability.activatedAt == started)
        #expect(availability.expiresAt == expires)
        #expect(availability.heartbeatAt == refreshedAt)
        #expect(availability.isReady(at: refreshedAt))
    }

    @Test func standbyAcceptsARequestThatRacedWithRearming() {
        let started = Date(timeIntervalSince1970: 10_000)
        let availability = QuickDictationAvailability(
            activatedAt: started,
            expiresAt: started.addingTimeInterval(600)
        )

        #expect(availability.acceptsRequest(createdAt: started.addingTimeInterval(-1)))
        #expect(!availability.acceptsRequest(createdAt: started.addingTimeInterval(-3)))
        #expect(!availability.acceptsRequest(createdAt: availability.expiresAt))
    }

    @Test func oldAvailabilityFilesWithoutAHeartbeatAreStale() throws {
        let json = """
        {"activatedAt":"2026-01-01T00:00:00Z","expiresAt":"2027-01-01T00:00:00Z",\
        "schemaVersion":1}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let availability = try decoder.decode(
            QuickDictationAvailability.self,
            from: Data(json.utf8)
        )

        #expect(availability.heartbeatAt == nil)
        #expect(!availability.isReady(at: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func cursorTrackpadEmitsOnlyWholeCharacterSteps() {
        #expect(CursorTrackpad.step(forHorizontalTranslation: 9.9) == 0)
        #expect(CursorTrackpad.step(forHorizontalTranslation: 10) == 1)
        #expect(CursorTrackpad.step(forHorizontalTranslation: 27) == 2)
        #expect(CursorTrackpad.step(forHorizontalTranslation: -9.9) == 0)
        #expect(CursorTrackpad.step(forHorizontalTranslation: -10) == -1)
    }

    @Test func diagnosticsHaveNoPrivateContentFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("diagnostics.ndjson")
        DiagnosticLog.append(
            DiagnosticEntry(
                timestamp: Date(timeIntervalSince1970: 10_000),
                source: .keyboard,
                event: .sessionStateChanged,
                metadata: .state(.recording)
            ),
            to: file
        )

        let contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(contents.contains("sessionStateChanged"))
        #expect(contents.contains("recording"))
        #expect(!contents.localizedCaseInsensitiveContains("transcript"))
        #expect(!contents.localizedCaseInsensitiveContains("audioPath"))
        #expect(!contents.localizedCaseInsensitiveContains("token"))
        #expect(!contents.localizedCaseInsensitiveContains("gatewayURL"))
    }

    @Test func diagnosticExportDropsEntriesOlderThanSevenDays() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let old = DiagnosticEntry(
            timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60),
            source: .app,
            event: .appStarted
        )
        let recent = DiagnosticEntry(
            timestamp: now.addingTimeInterval(-60),
            source: .app,
            event: .quickDictationArmed
        )
        let contents = try [old, recent]
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")

        let retained = DiagnosticLog.retainedEntries(from: contents, now: now)
        #expect(retained.count == 1)
        #expect(retained[0].contains("quickDictationArmed"))
    }

    @Test func diagnosticFileIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("diagnostics.ndjson")
        try Data(repeating: 0x78, count: DiagnosticLog.maximumFileSize + 1_000)
            .write(to: file)

        DiagnosticLog.append(
            DiagnosticEntry(source: .tests, event: .appStarted),
            to: file
        )

        let size = try #require(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size <= DiagnosticLog.maximumFileSize)
    }
}
