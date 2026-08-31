import Foundation
import Testing

struct ReliabilityFeatureTests {
    @Test func latencySensitiveSessionStatesUseResponsiveFallbackPolling() {
        for state in [
            SessionState.recording,
            .finalizing,
            .uploading,
            .transcribing,
        ] {
            #expect(
                SessionPollingPolicy.interval(for: state)
                    == SessionPollingPolicy.responsiveInterval
            )
        }
        #expect(
            SessionPollingPolicy.interval(for: .readyToInsert)
                == SessionPollingPolicy.relaxedInterval
        )
        #expect(SessionPollingPolicy.interval(for: .completed) == nil)
    }

    @Test func freshBatchCapabilitySkipsOnlyTheMatchingGateway() throws {
        let gateway = try #require(URL(string: "http://gateway.local:8765"))
        let checkedAt = Date(timeIntervalSince1970: 10_000)

        #expect(!GatewayStreamingPolicy.shouldAttemptStreaming(
            supported: false,
            checkedAt: checkedAt,
            cachedBaseURL: gateway.absoluteString,
            currentBaseURL: gateway,
            now: checkedAt.addingTimeInterval(30)
        ))
        #expect(GatewayStreamingPolicy.shouldAttemptStreaming(
            supported: false,
            checkedAt: checkedAt,
            cachedBaseURL: "http://another-gateway.local:8765",
            currentBaseURL: gateway,
            now: checkedAt.addingTimeInterval(30)
        ))
        #expect(GatewayStreamingPolicy.shouldAttemptStreaming(
            supported: false,
            checkedAt: checkedAt,
            cachedBaseURL: gateway.absoluteString,
            currentBaseURL: gateway,
            now: checkedAt.addingTimeInterval(
                GatewayStreamingPolicy.capabilityFreshnessInterval + 1
            )
        ))
    }

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

    /// The bug this replaced: stopping standby from the Dynamic Island wrote the
    /// durable preference, so Quick Dictation stayed off until the user found
    /// the switch in Settings. The two states are separate now, and every
    /// arming path asks for both at once through `quickDictationArmable`.
    @Test func pausingLeavesTheDurablePreferenceOn() {
        let enabled = KeyboardPreferences.quickDictationEnabled
        let paused = KeyboardPreferences.quickDictationPausedUntilRelaunch
        defer {
            KeyboardPreferences.quickDictationEnabled = enabled
            KeyboardPreferences.quickDictationPausedUntilRelaunch = paused
        }

        KeyboardPreferences.quickDictationEnabled = true
        KeyboardPreferences.quickDictationPausedUntilRelaunch = false
        #expect(KeyboardPreferences.quickDictationArmable)

        // The Live Activity's Pause button, which is what
        // `StopQuickDictationIntent` writes.
        KeyboardPreferences.quickDictationPausedUntilRelaunch = true
        #expect(!KeyboardPreferences.quickDictationArmable)
        #expect(KeyboardPreferences.quickDictationEnabled)

        // Reopening vocaphone, which is `endQuickDictationPause`.
        KeyboardPreferences.quickDictationPausedUntilRelaunch = false
        #expect(KeyboardPreferences.quickDictationArmable)

        // The Settings switch is the one that persists: clearing the pause does
        // not undo it.
        KeyboardPreferences.quickDictationEnabled = false
        #expect(!KeyboardPreferences.quickDictationArmable)
        KeyboardPreferences.quickDictationPausedUntilRelaunch = false
        #expect(!KeyboardPreferences.quickDictationArmable)
    }

    /// Both new preferences are absent for everyone upgrading, and the defaults
    /// they fall back to have to be the behaviour those users already have.
    @Test func newQuickDictationPreferencesDefaultToTodaysBehaviour() {
        let storedDuration = KeyboardPreferences.defaults?
            .string(forKey: KeyboardPreferences.quickDictationDurationKey)
        let paused = KeyboardPreferences.quickDictationPausedUntilRelaunch
        defer {
            if let storedDuration {
                KeyboardPreferences.defaults?
                    .set(storedDuration, forKey: KeyboardPreferences.quickDictationDurationKey)
            } else {
                KeyboardPreferences.defaults?
                    .removeObject(forKey: KeyboardPreferences.quickDictationDurationKey)
            }
            KeyboardPreferences.quickDictationPausedUntilRelaunch = paused
        }

        KeyboardPreferences.defaults?
            .removeObject(forKey: KeyboardPreferences.quickDictationDurationKey)
        KeyboardPreferences.defaults?
            .removeObject(forKey: KeyboardPreferences.quickDictationPausedKey)

        #expect(KeyboardPreferences.quickDictationDuration == .tenMinutes)
        #expect(!KeyboardPreferences.quickDictationPausedUntilRelaunch)
    }

    @Test func standbyWindowsMatchTheDurationTheUserPicked() {
        let armedAt = Date(timeIntervalSince1970: 10_000)

        #expect(
            QuickDictationDuration.tenMinutes.expiry(from: armedAt)
                == armedAt.addingTimeInterval(600)
        )
        #expect(
            QuickDictationDuration.twentyMinutes.expiry(from: armedAt)
                == armedAt.addingTimeInterval(1_200)
        )
        #expect(!QuickDictationDuration.tenMinutes.renewsLease)
        #expect(!QuickDictationDuration.twentyMinutes.renewsLease)
        #expect(QuickDictationDuration.untilAppCloses.renewsLease)
        // An unlimited window still takes a bounded lease, so a process that
        // dies between heartbeats cannot leave a marker claiming the microphone
        // is ready forever.
        #expect(QuickDictationDuration.untilAppCloses.leaseSeconds > 0)
    }

    /// Every raw value is persisted, so renaming a case silently resets the
    /// preference for everyone who chose it.
    @Test func durationRawValuesAreStable() {
        #expect(QuickDictationDuration.tenMinutes.rawValue == "tenMinutes")
        #expect(QuickDictationDuration.twentyMinutes.rawValue == "twentyMinutes")
        #expect(QuickDictationDuration.untilAppCloses.rawValue == "untilAppCloses")
        #expect(QuickDictationDuration(rawValue: "nonsense") == nil)
    }

    @Test func onlyAnUnlimitedWindowMovesItsDeadline() {
        let started = Date(timeIntervalSince1970: 10_000)
        let bounded = QuickDictationAvailability(
            activatedAt: started,
            expiresAt: QuickDictationDuration.tenMinutes.expiry(from: started)
        )
        let laterOn = started.addingTimeInterval(120)

        let heldWindow = bounded.renewingLease(.tenMinutes, at: laterOn)
        #expect(heldWindow.expiresAt == bounded.expiresAt)
        #expect(heldWindow.heartbeatAt == laterOn)
        #expect(heldWindow.isReady(at: laterOn))

        let rolling = QuickDictationAvailability(
            activatedAt: started,
            expiresAt: QuickDictationDuration.untilAppCloses.expiry(from: started)
        ).renewingLease(.untilAppCloses, at: laterOn)
        #expect(rolling.activatedAt == started)
        #expect(rolling.expiresAt == QuickDictationDuration.untilAppCloses.expiry(from: laterOn))
        #expect(rolling.isReady(at: laterOn))
        // And it dies on its own once the heartbeats stop.
        #expect(!rolling.isReady(at: laterOn.addingTimeInterval(30)))
    }

    /// The offer exists for people an older build switched off, and it must not
    /// reach anybody else — nor reappear after it has been answered.
    @Test func theRecoveryOfferIsRaisedOnlyForInstallsThatArriveTurnedOff() {
        #expect(QuickDictationRecoveryOffer.make(isPending: true, isEnabled: false) != nil)
        // Already on: nothing to ask, whoever turned it on.
        #expect(QuickDictationRecoveryOffer.make(isPending: true, isEnabled: true) == nil)
        // Answered, or never affected.
        #expect(QuickDictationRecoveryOffer.make(isPending: false, isEnabled: false) == nil)
        #expect(QuickDictationRecoveryOffer.make(isPending: false, isEnabled: true) == nil)
    }

    /// The migration marks the offer; it must never turn the microphone back on
    /// by itself, and it must run exactly once so "Not now" stays answered.
    @Test func theRecoveryMigrationAsksRatherThanReArmingTheMicrophone() {
        let defaults = KeyboardPreferences.defaults
        let enabled = KeyboardPreferences.quickDictationEnabled
        let offer = KeyboardPreferences.quickDictationRecoveryOfferPending
        let migrated = defaults?
            .object(forKey: KeyboardPreferences.quickDictationRecoveryMigrationKey)
        defer {
            KeyboardPreferences.quickDictationEnabled = enabled
            KeyboardPreferences.quickDictationRecoveryOfferPending = offer
            if let migrated {
                defaults?.set(migrated, forKey: KeyboardPreferences.quickDictationRecoveryMigrationKey)
            } else {
                defaults?.removeObject(forKey: KeyboardPreferences.quickDictationRecoveryMigrationKey)
            }
        }

        func resetMigration() {
            defaults?.removeObject(forKey: KeyboardPreferences.quickDictationRecoveryMigrationKey)
            KeyboardPreferences.quickDictationRecoveryOfferPending = false
        }

        // An install that arrives with the feature off is asked, and the stored
        // preference is left exactly as the user's older build left it.
        resetMigration()
        KeyboardPreferences.quickDictationEnabled = false
        KeyboardPreferences.markQuickDictationRecoveryOfferIfNeeded()
        #expect(KeyboardPreferences.quickDictationRecoveryOfferPending)
        #expect(!KeyboardPreferences.quickDictationEnabled)

        // Answering it sticks: the migration has already run, so a later launch
        // does not raise the card again.
        KeyboardPreferences.quickDictationRecoveryOfferPending = false
        KeyboardPreferences.markQuickDictationRecoveryOfferIfNeeded()
        #expect(!KeyboardPreferences.quickDictationRecoveryOfferPending)

        // An install that arrives with the feature on is never asked anything.
        resetMigration()
        KeyboardPreferences.quickDictationEnabled = true
        KeyboardPreferences.markQuickDictationRecoveryOfferIfNeeded()
        #expect(!KeyboardPreferences.quickDictationRecoveryOfferPending)
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
                uptimeMilliseconds: 42_123,
                source: .keyboard,
                event: .finishRequested,
                metadata: .state(.recording)
            ),
            to: file
        )

        let contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(contents.contains("finishRequested"))
        #expect(contents.contains("recording"))
        #expect(contents.contains("42123"))
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
