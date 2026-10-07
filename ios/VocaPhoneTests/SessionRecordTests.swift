import Foundation
import Testing

struct SessionRecordTests {
    @Test func validTransitionIncrementsRevision() throws {
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        #expect(record.state == .launchingApp)
        #expect(record.revision == 1)
    }

    @Test func invalidTransitionIsRejected() {
        var record = SessionRecord()
        #expect(throws: SessionTransitionError.invalid(from: .idle, to: .readyToInsert)) {
            try record.transition(to: .readyToInsert)
        }
    }

    /// A microphone another app silenced produces a file that no retry can turn
    /// into a transcript, so finishing must be able to fail permanently without
    /// first pretending the recording is worth uploading.
    @Test func aCaptureKnownUnusableFailsWithoutBeingUploaded() throws {
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try record.transition(to: .recording)
        try record.transition(to: .finalizing)
        try record.transition(to: .transcriptionFailedPermanent)

        #expect(record.state.isTerminal)
        #expect(!record.canRetry)
    }

    @Test func sharedStoreRoundTripsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try store.save(record)
        #expect(try store.load(record.sessionID) == record)
    }

    @Test func failedTranscriptDeletionKeepsTheRecordAndThrows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FailingRemovalFileManager()
        let store = SharedStore(fileManager: fileManager, rootOverride: root)
        let record = SessionRecord()
        try store.save(record)
        fileManager.blockedNames = [record.sessionID.uuidString.lowercased() + ".json"]

        #expect(throws: CocoaError.self) { try store.delete(record.sessionID) }
        #expect(try store.load(record.sessionID) != nil)

        fileManager.blockedNames = []
        try store.delete(record.sessionID)
        #expect(try store.load(record.sessionID) == nil)
    }

    @Test func bulkDeletionReportsFilesItCouldNotRemove() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FailingRemovalFileManager()
        let store = SharedStore(fileManager: fileManager, rootOverride: root)
        let kept = SessionRecord()
        let removed = SessionRecord()
        try store.save(kept)
        try store.save(removed)
        let liveName = kept.sessionID.uuidString.lowercased() + ".live"
        let live = root.appendingPathComponent("sessions/\(liveName)")
        try Data("private words".utf8).write(to: live)
        fileManager.blockedNames = [liveName]

        #expect(throws: CocoaError.self) { try store.deleteAllSessions() }
        #expect(try store.load(kept.sessionID) != nil)
        #expect(try store.load(removed.sessionID) == nil)
        #expect(FileManager.default.fileExists(atPath: live.path))

        fileManager.blockedNames = []
        #expect(try store.deleteAllSessions() == 2)
        #expect(try store.load(kept.sessionID) == nil)
        #expect(!FileManager.default.fileExists(atPath: live.path))
    }

    @Test func partialTranscriptDeletionCanBeRetried() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FailingRemovalFileManager()
        let store = SharedStore(fileManager: fileManager, rootOverride: root)
        let record = SessionRecord(state: .completed)
        try store.save(record)
        try store.saveMeter(MeterSample(sequence: 1, levels: [0.5]), for: record.sessionID)
        let meterName = record.sessionID.uuidString.lowercased() + ".meter"
        fileManager.blockedNames = [meterName]

        #expect(throws: CocoaError.self) { try store.delete(record.sessionID) }
        #expect(try store.load(record.sessionID) != nil)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("sessions/\(meterName)").path
        ))

        fileManager.blockedNames = []
        try store.delete(record.sessionID)
        #expect(try store.load(record.sessionID) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("sessions/\(meterName)").path
        ))
    }

    @Test func activeRecordingCannotBeDeletedOrStrandedByDeleteAll() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SharedStore(rootOverride: root)
        let active = SessionRecord(state: .recording)
        let finished = SessionRecord(state: .completed)
        try store.save(active)
        try store.save(finished)
        try store.saveLiveTranscript("private words", for: active.sessionID)

        #expect(throws: SharedStoreError.self) { try store.delete(active.sessionID) }
        #expect(throws: SharedStoreError.self) { try store.deleteAllSessions() }
        #expect(try store.load(active.sessionID) != nil)
        #expect(try store.load(finished.sessionID) != nil)
        #expect(store.liveTranscript(for: active.sessionID) == "private words")

        var stopped = active
        try stopped.transition(to: .finalizing)
        try stopped.transition(to: .transcriptionFailedPermanent)
        try store.save(stopped)
        #expect(try store.deleteAllSessions() == 2)
        #expect(try store.load(active.sessionID) == nil)
        #expect(try store.load(finished.sessionID) == nil)
        #expect(store.liveTranscript(for: active.sessionID) == nil)
    }

    @Test func storagePruningLeavesAnActiveRecordingAndItsWordsAlone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SharedStore(rootOverride: root)
        let active = SessionRecord(state: .recording)
        try store.save(active)
        try store.saveLiveTranscript("private words", for: active.sessionID)

        #expect(try store.pruneSessions(keeping: 0) == 0)
        #expect(try store.load(active.sessionID) != nil)
        #expect(store.liveTranscript(for: active.sessionID) == "private words")
    }

    @Test func retentionKeepsRecordUntilPrivateLiveSidecarIsGone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FailingRemovalFileManager()
        let store = SharedStore(fileManager: fileManager, rootOverride: root)
        let record = SessionRecord(state: .completed, now: Date(timeIntervalSince1970: 100))
        try store.save(record)
        let liveName = record.sessionID.uuidString.lowercased() + ".live"
        let live = root.appendingPathComponent("sessions/\(liveName)")
        try Data("private words".utf8).write(to: live)
        fileManager.blockedNames = [liveName]
        let now = Date(timeIntervalSince1970: 100 + 3 * 86_400)

        #expect(throws: CocoaError.self) {
            try store.pruneTranscripts(olderThan: 86_400, now: now)
        }
        #expect(try store.load(record.sessionID) != nil)
        #expect(FileManager.default.fileExists(atPath: live.path))

        fileManager.blockedNames = []
        #expect(try store.pruneTranscripts(olderThan: 86_400, now: now) == 1)
        #expect(try store.load(record.sessionID) == nil)
        #expect(!FileManager.default.fileExists(atPath: live.path))
    }

    @Test func storagePruningKeepsRecordUntilLiveSidecarIsGone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FailingRemovalFileManager()
        let store = SharedStore(fileManager: fileManager, rootOverride: root)
        let record = SessionRecord(state: .completed, now: Date(timeIntervalSince1970: 100))
        try store.save(record)
        let liveName = record.sessionID.uuidString.lowercased() + ".live"
        let live = root.appendingPathComponent("sessions/\(liveName)")
        try Data("private words".utf8).write(to: live)
        fileManager.blockedNames = [liveName]

        #expect(throws: CocoaError.self) {
            try store.pruneSessions(keeping: 0)
        }
        #expect(try store.load(record.sessionID) != nil)

        fileManager.blockedNames = []
        #expect(try store.pruneSessions(keeping: 0) == 1)
        #expect(try store.load(record.sessionID) == nil)
        #expect(!FileManager.default.fileExists(atPath: live.path))
    }

    @Test func oldOrphanedLiveSidecarsAreRecoveredWithoutTouchingFreshOnes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SharedStore(rootOverride: root)
        let active = SessionRecord(state: .recording)
        try store.save(active)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let oldOrphan = sessions.appendingPathComponent("old.live")
        let freshOrphan = sessions.appendingPathComponent("fresh.live")
        let activeLive = sessions.appendingPathComponent(active.sessionID.uuidString.lowercased() + ".live")
        for file in [oldOrphan, freshOrphan, activeLive] {
            try Data("private words".utf8).write(to: file)
        }
        let now = Date(timeIntervalSince1970: 10_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: oldOrphan.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: activeLive.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: freshOrphan.path
        )

        #expect(try store.pruneOrphanedSessionSidecars(now: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: oldOrphan.path))
        #expect(FileManager.default.fileExists(atPath: freshOrphan.path))
        #expect(FileManager.default.fileExists(atPath: activeLive.path))
    }

    @Test func transcriptRetentionDoesNotCountFailedRemoval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FailingRemovalFileManager()
        let store = SharedStore(fileManager: fileManager, rootOverride: root)
        let record = SessionRecord(state: .completed, now: Date(timeIntervalSince1970: 100))
        try store.save(record)
        fileManager.blockedNames = [record.sessionID.uuidString.lowercased() + ".json"]
        let now = Date(timeIntervalSince1970: 100 + 3 * 86_400)

        #expect(throws: CocoaError.self) {
            try store.pruneTranscripts(olderThan: 86_400, now: now)
        }
        #expect(try store.load(record.sessionID) != nil)

        fileManager.blockedNames = []
        #expect(try store.pruneTranscripts(olderThan: 86_400, now: now) == 1)
        #expect(try store.load(record.sessionID) == nil)
    }

    @Test func meterUpdatesCannotOverwriteAKeyboardStateTransition() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try record.transition(to: .recording)
        try store.save(record)
        try store.saveMeter(MeterSample(sequence: 5, levels: [0.2, 0.8]), for: record.sessionID)

        let recording = try #require(try store.load(record.sessionID))
        #expect(recording.state == .recording)
        #expect(recording.meterLevel == 0.8)

        try record.transition(to: .finalizing)
        try store.save(record)
        // Simulate one late microphone callback racing with the keyboard tap.
        try store.saveMeter(MeterSample(sequence: 7, levels: [0.4]), for: record.sessionID)

        let finalizing = try #require(try store.load(record.sessionID))
        #expect(finalizing.state == .finalizing)
        #expect(finalizing.meterLevel == 0)
    }

    /// The words heard so far live only while the session records, and never
    /// outlive the session they belong to.
    @Test func liveTranscriptIsDroppedWhenRecordingEnds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try record.transition(to: .recording)
        try store.save(record)
        try store.saveLiveTranscript("so we should ship it", for: record.sessionID)
        #expect(store.liveTranscript(for: record.sessionID) == "so we should ship it")

        try record.transition(to: .finalizing)
        try store.save(record)
        #expect(store.liveTranscript(for: record.sessionID) == nil)

        // A preview that lands after the keyboard's Finish is not kept.
        try store.saveLiveTranscript("late", for: record.sessionID)
        #expect(store.liveTranscript(for: record.sessionID) == nil)
        try record.transition(to: .transcriptionFailedPermanent)
        try store.save(record)
        try store.delete(record.sessionID)
        #expect(store.liveTranscript(for: record.sessionID) == nil)
        #expect(try store.recent().isEmpty)
    }

    @Test func retryWithoutANewCaptureKeepsTheOriginalDuration() {
        var record = SessionRecord()
        record.recordedSeconds = 12.5

        record.recordCaptureDuration(startedAt: nil)

        #expect(record.recordedSeconds == 12.5)
    }

    @Test func aNewCaptureReplacesThePreviousDuration() {
        var record = SessionRecord()
        record.recordedSeconds = 12.5

        record.recordCaptureDuration(
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 104.25)
        )

        #expect(record.recordedSeconds == 4.25)
    }

    @Test func aParkedTranscriptSurvivesUntilTheOriginalFieldReturns() throws {
        var record = SessionRecord()
        for state in [
            SessionState.launchingApp, .recording, .finalizing, .uploading,
            .transcribing, .readyToInsert,
        ] {
            try record.transition(to: state)
        }

        try record.transition(to: .targetContextChanged)
        #expect(!record.state.isTerminal)

        try record.transition(to: .readyToInsert)
        try record.transition(to: .inserting)
        #expect(record.state == .inserting)
    }

    @Test func aParkedTranscriptCanBeDiscarded() throws {
        var record = SessionRecord()
        for state in [
            SessionState.launchingApp, .recording, .finalizing, .uploading,
            .transcribing, .readyToInsert, .targetContextChanged,
        ] {
            try record.transition(to: state)
        }

        try record.transition(to: .canceled)
        #expect(record.state.isTerminal)
    }

    @Test func inContainingAppFlagRoundTripsAndDefaultsToUnknown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)

        var record = SessionRecord()
        #expect(record.startedInContainingApp == nil)
        record.startedInContainingApp = true
        try record.transition(to: .launchingApp)
        try store.save(record)

        #expect(try store.load(record.sessionID)?.startedInContainingApp == true)
    }

    @Test func quickDictationPreferenceRoundTripsAndDefaultsToUnknown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)

        var record = SessionRecord()
        #expect(record.prefersQuickDictation == nil)
        record.prefersQuickDictation = true
        try record.transition(to: .launchingApp)
        try store.save(record)

        #expect(try store.load(record.sessionID)?.prefersQuickDictation == true)
    }

    /// Records written before the field existed must still decode, otherwise a
    /// pending dictation would be dropped on upgrade.
    @Test func recordsWithoutTheContainingAppFlagStillDecode() throws {
        let json = """
        {"createdAt":"2026-01-01T00:00:00Z","language":"auto","meterLevel":0,\
        "revision":1,"schemaVersion":1,"sessionID":"11111111-1111-1111-1111-111111111111",\
        "state":"recording","style":"casual","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SessionRecord.self, from: Data(json.utf8))

        #expect(record.startedInContainingApp == nil)
        #expect(record.prefersQuickDictation == nil)
        #expect(record.state == .recording)
        // No processing location either. The interface answers that with
        // neutral wording rather than guessing a route.
        #expect(record.processingLocation == nil)
        // No target fingerprint: such a record keeps inserting where it always
        // did. And nothing marks it as an interrupted insertion.
        #expect(record.targetFingerprint == nil)
        #expect(record.insertionInterrupted == nil)
        #expect(record.fileIncompleteUntold == nil)
    }

    /// The fingerprint is written by the keyboard at creation and has to
    /// survive every write the app makes on the way to `readyToInsert`.
    @Test func theTargetFingerprintSurvivesTheStoreAndTheApp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        var record = SessionRecord()
        record.targetFingerprint = "0123456789abcdef"
        for state in [
            SessionState.launchingApp, .recording, .finalizing, .uploading,
            .transcribing, .readyToInsert,
        ] {
            try record.transition(to: state)
            try store.save(record)
            record = try #require(try store.load(record.sessionID))
        }
        #expect(record.targetFingerprint == "0123456789abcdef")
        #expect(record.insertionInterrupted == nil)
    }

    /// A file cut short by a failed write stays flagged through a failure and
    /// the shared store. The retry that follows has no streamed copy left, so
    /// the flag is all that stops it using the file as the whole recording
    /// before the user has been told.
    @Test func anUntoldIncompleteFileSurvivesAFailureAndTheStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)

        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try record.transition(to: .recording)
        try record.transition(to: .finalizing)
        record.fileIncompleteUntold = true
        try record.transition(to: .uploading)
        try record.transition(to: .transcribing)
        try record.transition(to: .transcriptionFailedRecoverable)
        try store.save(record)

        var retried = try #require(try store.load(record.sessionID))
        try retried.transition(to: .uploading)
        #expect(retried.fileIncompleteUntold == true)
    }

    /// Both routes survive a write and a read through the shared container,
    /// which is the only channel the keyboard and the Live Activity have for
    /// learning where the work is happening.
    @Test func bothProcessingLocationsRoundTripThroughTheSharedStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)

        for location in [SessionProcessingLocation.onDevice, .gateway] {
            var record = SessionRecord()
            record.processingLocation = location
            try store.save(record)
            #expect(try store.load(record.sessionID)?.processingLocation == location)
        }
    }

    /// A route recorded at claim time has to survive every later transition:
    /// the keyboard reads it while the app is in the background and cannot ask
    /// again.
    @Test func theProcessingLocationSurvivesTransitions() throws {
        var record = SessionRecord()
        record.processingLocation = .gateway
        try record.transition(to: .launchingApp)
        try record.transition(to: .recording)
        try record.transition(to: .finalizing)
        try record.transition(to: .uploading)

        #expect(record.processingLocation == .gateway)
    }

    @Test func mostRecentReturnsTheNewestSessionWithoutScanningEverything() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        let identifiers = try Self.seedSessions(count: 3, in: directory, store: store)

        #expect(try store.mostRecent()?.sessionID == identifiers.last)
    }

    @Test func recentTranscriptsSkipsNewerSessionsWithoutWordsBeforeLimiting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var expected: [UUID] = []
        for index in 0..<6 {
            var record = SessionRecord(now: base.addingTimeInterval(Double(index)))
            if index < 3 {
                record.transcript = "Transcript \(index)"
                expected.append(record.sessionID)
            }
            try store.save(record)
            let file = directory.appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(record.sessionID.uuidString.lowercased())
                .appendingPathExtension("json")
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(Double(index))],
                ofItemAtPath: file.path
            )
        }

        #expect(try store.recentTranscripts(limit: 3).map(\.sessionID) == expected.reversed())
        #expect(try store.recentTranscripts(limit: 0).isEmpty)
    }

    @Test func pruningKeepsOnlyTheNewestSessions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        let identifiers = try Self.seedSessions(count: 5, in: directory, store: store)

        #expect(try store.pruneSessions(keeping: 2) == 3)
        #expect(try store.recent(limit: 10).map(\.sessionID) == identifiers.suffix(2).reversed())
    }

    @Test func pruningDropsStaleTerminalSessionsInsideTheWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        var record = SessionRecord(now: Date(timeIntervalSince1970: 1_000))
        try record.transition(to: .launchingApp, now: Date(timeIntervalSince1970: 1_000))
        try record.transition(to: .canceled, now: Date(timeIntervalSince1970: 1_000))
        try store.save(record)

        let laterThanRetention = Date(timeIntervalSince1970: 1_000 + 8 * 24 * 60 * 60)
        #expect(try store.pruneSessions(keeping: 50, now: laterThanRetention) == 1)
        #expect(try store.mostRecent() == nil)
    }

    /// The bar offers Cancel in every live state, so every live state has to
    /// accept it. Transcription did not, and the tap reported "The session
    /// changed. Please try again." while the session carried on regardless.
    @Test func cancelIsAcceptedWhereverTheBarOffersIt() throws {
        for abandonAfter in [
            SessionState.launchingApp, .awaitingReturn, .recording, .finalizing,
            .uploading, .transcribing, .readyToInsert, .targetContextChanged,
        ] {
            var record = SessionRecord()
            for state in Self.route(to: abandonAfter) {
                try record.transition(to: state)
            }
            #expect(record.state == abandonAfter)
            try record.transition(to: .canceled)
            #expect(record.state.isTerminal)
        }
    }

    /// The shortest legal sequence of transitions that arrives at `state`.
    private static func route(to state: SessionState) -> [SessionState] {
        let pipeline: [SessionState] = [
            .launchingApp, .recording, .finalizing, .uploading, .transcribing,
            .readyToInsert, .targetContextChanged,
        ]
        if state == .awaitingReturn { return [.launchingApp, .awaitingReturn] }
        guard let end = pipeline.firstIndex(of: state) else { return [state] }
        return Array(pipeline.prefix(through: end))
    }

    // MARK: - Expiry

    /// The keyboard adopts the newest non-terminal session every time it
    /// appears, in any app. A hand-off nobody completed therefore has to become
    /// terminal on its own, or it is a permanent "Opening vocaphone" bar.
    @Test func anUncompletedHandoffExpiresRatherThanWaitingForever() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        for state in [SessionState.launchingApp, .awaitingReturn] {
            var record = SessionRecord(now: start)
            try record.transition(to: .launchingApp, now: start)
            if state == .awaitingReturn {
                try record.transition(to: .awaitingReturn, now: start)
            }

            let withinWindow = start.addingTimeInterval(
                SessionExpiryPolicy.handoffWindow - 1
            )
            #expect(!SessionExpiryPolicy.isStale(record, now: withinWindow))
            #expect(SessionExpiryPolicy.isStale(
                record,
                now: start.addingTimeInterval(SessionExpiryPolicy.handoffWindow + 1)
            ))
        }
    }

    /// The audio the user is speaking must never be retired underneath them, so
    /// the capture window has to clear the hard recording cap by a wide margin.
    @Test func aLiveRecordingOutlastsTheCapItIsAlreadyBoundedBy() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var record = SessionRecord(now: start)
        try record.transition(to: .launchingApp, now: start)
        try record.transition(to: .recording, now: start)

        #expect(!SessionExpiryPolicy.isStale(
            record,
            now: start.addingTimeInterval(AppConfiguration.maximumRecordingSeconds + 60)
        ))
        #expect(SessionExpiryPolicy.isStale(
            record,
            now: start.addingTimeInterval(SessionExpiryPolicy.captureWindow + 1)
        ))
    }

    /// A transcript in flight belongs to the field it was dictated for, and the
    /// hand-off back to that field is measured in seconds. Keeping it offered
    /// indefinitely is what let yesterday's dictation land in today's field.
    @Test func anAbandonedTranscriptStopsBeingOfferedEventually() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var record = SessionRecord(now: start)
        for state in [
            SessionState.launchingApp, .recording, .finalizing, .uploading,
            .transcribing, .readyToInsert,
        ] {
            try record.transition(to: state, now: start)
        }

        #expect(!SessionExpiryPolicy.isStale(record, now: start.addingTimeInterval(60)))
        #expect(SessionExpiryPolicy.isStale(
            record,
            now: start.addingTimeInterval(SessionExpiryPolicy.pendingUserActionWindow + 1)
        ))
    }

    // MARK: - Interrupted insertion

    /// A record left in `inserting` by a keyboard that ended mid-insertion.
    private static func stuckInsertion(at start: Date) throws -> SessionRecord {
        var record = SessionRecord(now: start)
        for state in [
            SessionState.launchingApp, .recording, .finalizing, .uploading,
            .transcribing, .readyToInsert, .inserting,
        ] {
            try record.transition(to: state, now: start)
        }
        record.transcript = "Meet at noon."
        return record
    }

    /// `inserting` used to have no way out but the two writes a killed keyboard
    /// never makes, so the record was adopted on every appearance and hid the
    /// keys behind "Inserting" until the app was reinstalled.
    @Test func aStuckInsertionCanBeOfferedAgainOrExpire() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var offered = try Self.stuckInsertion(at: start)
        try offered.transition(to: .readyToInsert)
        #expect(offered.state == .readyToInsert)

        let stuck = try Self.stuckInsertion(at: start)
        #expect(!SessionExpiryPolicy.isStale(stuck, now: start.addingTimeInterval(10)))
        #expect(SessionExpiryPolicy.isStale(
            stuck,
            now: start.addingTimeInterval(SessionExpiryPolicy.insertionWindow + 1)
        ))
        var expiring = stuck
        try expiring.transition(to: .expired)
        #expect(expiring.state.isTerminal)
    }

    /// The keyboard takes over only an insertion nobody is running: not its
    /// own, not one written a moment ago, and not one so old that expiry is the
    /// honest answer.
    @Test func onlyAnAbandonedInsertionIsOfferedAgain() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let stuck = try Self.stuckInsertion(at: start)
        let later = start.addingTimeInterval(60)

        #expect(InterruptedInsertion.decision(for: stuck, insertingHere: false, now: later)
            == .offerAgain)
        #expect(InterruptedInsertion.decision(for: stuck, insertingHere: true, now: later)
            == .notApplicable)
        #expect(InterruptedInsertion.decision(
            for: stuck,
            insertingHere: false,
            now: start.addingTimeInterval(InterruptedInsertion.gracePeriod - 1)
        ) == .wait)
        #expect(InterruptedInsertion.decision(
            for: stuck,
            insertingHere: false,
            now: start.addingTimeInterval(SessionExpiryPolicy.pendingUserActionWindow + 1)
        ) == .notApplicable)

        var ready = SessionRecord(now: start)
        for state in [
            SessionState.launchingApp, .recording, .finalizing, .uploading, .readyToInsert,
        ] {
            try ready.transition(to: state, now: start)
        }
        #expect(InterruptedInsertion.decision(for: ready, insertingHere: false, now: later)
            == .notApplicable)
    }

    /// Recovery is durable and flagged, so every keyboard instance agrees the
    /// transcript is waiting for a tap — and none of them inserts it on its own.
    @Test func recoveringAnInterruptedInsertionWritesThroughWithTheFlag() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        let start = Date(timeIntervalSince1970: 1_000)
        let stuck = try Self.stuckInsertion(at: start)
        try store.save(stuck)

        #expect(InterruptedInsertion.recoverIfInterrupted(
            stuck, in: store, insertingHere: false, now: start.addingTimeInterval(1)
        ) == nil)
        #expect(try store.load(stuck.sessionID)?.state == .inserting)

        let recovered = InterruptedInsertion.recoverIfInterrupted(
            stuck, in: store, insertingHere: false, now: start.addingTimeInterval(45)
        )
        #expect(recovered?.state == .readyToInsert)
        let stored = try #require(try store.load(stuck.sessionID))
        #expect(stored.state == .readyToInsert)
        #expect(stored.insertionInterrupted == true)
        #expect(stored.transcript == "Meet at noon.")
        // A fresh `readyToInsert` window: recovery must not hand the
        // transcript straight to expiry.
        #expect(!SessionExpiryPolicy.isStale(stored, now: start.addingTimeInterval(60)))
    }

    /// Delete, Delete all and storage pruning all refused a record with an
    /// active writer, and `inserting` counted as one forever.
    @Test func aStuckInsertionNoLongerBlocksDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SharedStore(rootOverride: root)
        let now = Date()
        let fresh = try Self.stuckInsertion(at: now)
        #expect(fresh.hasActiveWriter(now: now))
        try store.save(fresh)
        #expect(throws: SharedStoreError.self) { try store.delete(fresh.sessionID) }
        #expect(throws: SharedStoreError.self) { try store.deleteAllSessions() }

        let abandoned = try Self.stuckInsertion(
            at: now.addingTimeInterval(-(SessionExpiryPolicy.insertionWindow + 5))
        )
        #expect(!abandoned.hasActiveWriter(now: now))
        try store.save(abandoned)
        try store.delete(abandoned.sessionID)
        #expect(try store.load(abandoned.sessionID) == nil)

        try store.save(abandoned)
        #expect(try store.pruneSessions(keeping: 0, now: now) == 1)
        #expect(try store.load(abandoned.sessionID) == nil)
        #expect(try store.load(fresh.sessionID) != nil)
    }

    /// Terminal states have already stopped; expiring them again would rewrite
    /// finished history and re-notify every observer.
    @Test func settledSessionsAreNeverExpiredAgain() {
        for state in SessionState.allCases where state.isTerminal {
            #expect(SessionExpiryPolicy.window(for: state) == nil)
        }
    }

    /// Expiry is durable so the other process learns about it from the shared
    /// record rather than each one running its own timer.
    @Test func expiringWritesThroughSoBothProcessesAgree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        let start = Date(timeIntervalSince1970: 1_000)
        var record = SessionRecord(now: start)
        try record.transition(to: .launchingApp, now: start)
        try store.save(record)

        let fresh = SessionExpiryPolicy.expireIfStale(
            record,
            in: store,
            now: start.addingTimeInterval(10)
        )
        #expect(fresh == nil)
        #expect(try store.load(record.sessionID)?.state == .launchingApp)

        let expired = SessionExpiryPolicy.expireIfStale(
            record,
            in: store,
            now: start.addingTimeInterval(SessionExpiryPolicy.handoffWindow + 1)
        )
        #expect(expired?.state == .expired)
        #expect(try store.load(record.sessionID)?.state == .expired)
    }

    /// The keyboard's launch fallback reads this to tell "the app never heard
    /// me" from "the app is warming the microphone", which is the difference
    /// between rescuing a dictation and yanking the user out of their app.
    @Test func aClaimedHandoffRoundTripsAndDefaultsToUnclaimed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)

        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try store.save(record)
        #expect(try store.load(record.sessionID)?.claimedAt == nil)

        record.claimedAt = Date(timeIntervalSince1970: 2_000)
        try store.save(record)
        #expect(
            try store.load(record.sessionID)?.claimedAt
                == Date(timeIntervalSince1970: 2_000)
        )
        // Claiming is not a state change: the hand-off is still outstanding.
        #expect(try store.load(record.sessionID)?.state == .launchingApp)
    }

    /// Writes `count` sessions with explicit, increasing modification dates so
    /// recency ordering is deterministic rather than dependent on filesystem
    /// timestamp resolution. Returns identifiers oldest to newest.
    private static func seedSessions(
        count: Int,
        in root: URL,
        store: SharedStore
    ) throws -> [UUID] {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        return try (0..<count).map { index in
            var record = SessionRecord()
            try record.transition(to: .launchingApp)
            try record.transition(to: .canceled)
            try store.save(record)
            let file = sessions
                .appendingPathComponent(record.sessionID.uuidString.lowercased())
                .appendingPathExtension("json")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index))],
                ofItemAtPath: file.path
            )
            return record.sessionID
        }
    }

    @Test func insertionAddsOnlyNeededSpacing() {
        #expect(
            TextInsertion.preparedTranscript("hello", before: "Say", after: nil) == " hello"
        )
        #expect(
            TextInsertion.preparedTranscript("Hello.", before: nil, after: "Next") == "Hello. "
        )
        #expect(
            TextInsertion.preparedTranscript(",", before: "hello", after: " world") == ","
        )
    }

    @Test func quickDictationAvailabilityExpires() {
        let now = Date(timeIntervalSince1970: 1_000)
        let availability = QuickDictationAvailability(
            activatedAt: now,
            expiresAt: now.addingTimeInterval(600)
        )
        #expect(availability.isReady(at: now))
        #expect(!availability.isReady(at: now.addingTimeInterval(601)))
    }

    @Test func sharedStoreRoundTripsQuickDictationAvailability() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(rootOverride: directory)
        let availability = QuickDictationAvailability(
            expiresAt: Date().addingTimeInterval(600)
        )

        try store.saveQuickDictationAvailability(availability)
        #expect(try store.loadQuickDictationAvailability() == availability)
        try store.clearQuickDictationAvailability()
        #expect(try store.loadQuickDictationAvailability() == nil)
    }

    /// These raw values are the gateway's wire contract; the server rejects
    /// anything outside its own literal set.
    @Test func writingStylesHaveStableGatewayValues() {
        #expect(WritingStyle.raw.rawValue == "raw")
        #expect(WritingStyle.clean.rawValue == "clean")
        #expect(WritingStyle.formal.rawValue == "formal")
        #expect(WritingStyle.casual.rawValue == "casual")
        #expect(WritingStyle.veryCasual.rawValue == "very_casual")
        #expect(WritingStyle.excited.rawValue == "excited")
        #expect(SessionRecord().style == WritingStyle.casual.rawValue)
        #expect(WritingStyle.allCases.count == 6)
    }

    @Test func everyWritingStyleIsPresentableInThePicker() {
        for style in WritingStyle.allCases {
            #expect(!style.displayName.isEmpty)
            #expect(!style.detail.isEmpty)
            #expect(!style.example.isEmpty)
            #expect(!style.symbolName.isEmpty)
        }
        #expect(WritingStyle.raw.example == "ok so  this is vocaphone. it is a Keyboard")
        #expect(WritingStyle.clean.example == "all done for today.")
        #expect(WritingStyle.formal.example == "Please send the report today.")
        #expect(WritingStyle.casual.example == "I'll be there in ten")
        #expect(WritingStyle.veryCasual.example == "yeah all good, see you in ten")
        #expect(WritingStyle.excited.example == "This is going to be great!")
        #expect(Set(WritingStyle.allCases.map(\.example)).count == WritingStyle.allCases.count)
    }

    @Test func transcriptionLanguagesHaveStableGatewayValues() {
        #expect(TranscriptionLanguage.allCases.map(\.rawValue) == [
            "auto", "ar", "as", "bn", "bg", "yue", "ca", "hr", "cs", "da",
            "nl", "en", "et", "tl", "fi", "fr", "de", "el", "gu", "he",
            "hi", "hu", "id", "it", "ja", "kn", "ko", "lv", "lt", "ms",
            "ml", "mt", "zh", "mr", "ne", "no", "fa", "pl", "pt", "pa",
            "ro", "ru", "sr", "sk", "sl", "es", "sw", "sv", "ta", "te",
            "th", "tr", "uk", "ur", "vi",
        ])
        #expect(SessionRecord().language == TranscriptionLanguage.automatic.rawValue)
    }

    /// An unsupported language routes a transcribing session straight to the
    /// permanent failure state. Retrying replays the same language against the
    /// same model, so the session must be terminal and must not offer Retry.
    @Test func anUnsupportedLanguageFailsPermanentlyAndCannotBeRetried() throws {
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        try record.transition(to: .recording)
        try record.transition(to: .finalizing)
        try record.transition(to: .uploading)
        try record.transition(to: .transcribing)

        try record.transition(to: .transcriptionFailedPermanent)

        #expect(record.state.isTerminal)
        #expect(!record.canRetry)
    }

    @Test func microphonePreferencesHaveStableStoredValues() {
        #expect(MicrophonePreference.automatic.rawValue == "automatic")
        #expect(MicrophonePreference.iPhone.rawValue == "iphone")
    }

    /// Full-quality AirPods recording needs iOS 26; older systems are not
    /// promised it.
    @Test func automaticMicrophoneOnlyPromisesFullQualityAirPodsWhereItExists() {
        #expect(MicrophonePreference.automaticDetail(fullQualityAirPods: true).contains("full quality"))
        #expect(!MicrophonePreference.automaticDetail(fullQualityAirPods: false).contains("full quality"))
        #expect(MicrophonePreference.automaticDetail(fullQualityAirPods: false).contains("telephone-quality"))
    }

    @Test func gatewayEndpointAcceptsLANAndHTTPSHosts() {
        let lan = GatewayEndpoint.validatedURL(from: "  http://homelabone:8765/  ")
        let vps = GatewayEndpoint.validatedURL(from: "https://dictation.example.com")

        #expect(lan?.absoluteString == "http://homelabone:8765/")
        #expect(vps?.host == "dictation.example.com")
        #expect(lan.map(GatewayEndpoint.usesUnencryptedHTTP) == true)
        #expect(vps.map(GatewayEndpoint.usesUnencryptedHTTP) == false)
    }

    @Test func gatewayEndpointRejectsUnsupportedOrAmbiguousURLs() {
        #expect(GatewayEndpoint.validatedURL(from: "homelabone:8765") == nil)
        #expect(GatewayEndpoint.validatedURL(from: "ftp://homelabone/model") == nil)
        #expect(GatewayEndpoint.validatedURL(from: "https://user:password@example.com") == nil)
        #expect(GatewayEndpoint.validatedURL(from: "https://example.com?token=secret") == nil)
    }
}

private final class FailingRemovalFileManager: FileManager, @unchecked Sendable {
    var blockedNames: Set<String> = []

    override func removeItem(at URL: URL) throws {
        if blockedNames.contains(URL.lastPathComponent) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
