import Foundation
import SwiftUI
import UIKit

@MainActor
@Observable
final class RecordingCoordinator {
    private(set) var activeRecord: SessionRecord?
    private(set) var message: String?
    private(set) var quickDictationExpiresAt: Date?
    private(set) var currentMicrophoneName: String?
    /// Kept separate from `activeRecord` so a level update several times a
    /// second invalidates only the views that draw the meter.
    private(set) var meterLevel: Float = 0
    /// Guided setup reads system state that emits no change notifications —
    /// keyboard installation, a permission flipped in iOS Settings — so it is
    /// snapshotted here and refreshed deliberately rather than polled.
    private(set) var setupStatus = SetupStatus()

    private let recorder = AudioRecorder()
    private let store = SharedStore.shared
    private var pollingTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var pipelineSessionID: UUID?
    private var cancellationMonitorTask: Task<Void, Never>?
    private var quickDictationWatcherTask: Task<Void, Never>?
    private var startingSessionID: UUID?
    private var gatewayClient: GatewayClient?
    private var lastMicrophoneName: String?
    private var audioSessionAvailable = true
    private var audioLifecycleGeneration = 0
    private var darwinObservations: [VocaPhoneDarwinObservation] = []
    private let liveActivity = LiveActivityManager.shared
    private let streamingBridge = StreamingAudioBridge()
    private let soundFeedback = RecordingSoundFeedback()
    private var localSherpaSession: SherpaIncrementalSession?
    let localModels = LocalModelManager()

    var stateLabel: String { (activeRecord?.state ?? .idle).displayName }
    var isRecording: Bool { activeRecord?.state == .recording && recorder.isRecording }
    var hasError: Bool { activeRecord?.error != nil }
    var transcript: String? { activeRecord?.transcript }
    var isQuickDictationReady: Bool {
        guard let quickDictationExpiresAt else { return false }
        return recorder.isStandbyActive && quickDictationExpiresAt > Date()
    }
    /// Only true for a dictation started from another app, which is the only
    /// case where the user has somewhere to swipe back to.
    var isKeyboardRecording: Bool {
        isRecording
            && activeRecord?.sourceDocumentID != "in-app-test"
            && activeRecord?.startedInContainingApp != true
    }

    /// Dictation aimed at vocaphone's own text field. The keyboard stays on
    /// screen, so the transcript lands without any app switch.
    var isDictatingIntoContainingApp: Bool {
        isRecording && activeRecord?.startedInContainingApp == true
    }
    var canChangeMicrophone: Bool {
        !recorder.isRecording && startingSessionID == nil
    }
    var microphoneAccess: MicrophoneAccess {
        switch recorder.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    /// Re-reads every setup signal. Called on foreground and after any action
    /// that could have changed one, because none of them are observable: iOS
    /// exposes no API for whether a keyboard extension is installed, and a
    /// permission can be revoked from Settings while the app is suspended.
    func refreshSetupStatus() {
        let address = UserDefaults.standard.string(forKey: "gatewayURL") ?? ""
        let localReady: Bool = {
            guard LocalTranscriptionPreferences.enabled,
                  let modelID = LocalTranscriptionPreferences.modelIdentifier
            else { return false }
            return localModels.isDownloaded(modelID)
        }()
        let refreshed = SetupStatus(
            gatewayReady: localReady || UserDefaults.standard.bool(
                forKey: GatewayStatusPreferences.engineReadyKey
            ),
            gatewayAddress: localReady ? "" : address,
            microphone: microphoneAccess,
            keyboard: KeyboardSetupState.resolve(
                try? store.loadKeyboardStatus(),
                isInstalled: InstalledKeyboards.includesVocaPhone()
            ),
            hasDictatedOnce: KeyboardPreferences.hasCompletedFirstDictation
        )
        // Guided setup re-reads this several times a second while it waits for
        // the keyboard. Assigning an identical value would still invalidate
        // every observer, so the comparison earns its keep.
        guard refreshed != setupStatus else { return }
        setupStatus = refreshed
    }

    nonisolated func loadRecentTranscripts(limit: Int = 50) async -> [SessionRecord] {
        await Task.detached(priority: .userInitiated) {
            ((try? SharedStore.shared.recent(limit: limit)) ?? [])
                .filter { !($0.transcript ?? "").isEmpty }
        }.value
    }
    var microphoneStatusLabel: String {
        if let currentMicrophoneName { return currentMicrophoneName }
        if let lastMicrophoneName { return "Last used: \(lastMicrophoneName)" }
        switch KeyboardPreferences.microphonePreference {
        case .automatic: return "Selected when recording starts"
        case .iPhone: return "iPhone Microphone"
        }
    }

    init() {
        // A process exit can leave an otherwise valid-looking availability
        // marker behind. The new app process is not warm until it arms audio.
        try? store.clearQuickDictationAvailability()
        recorder.microphonePreference = KeyboardPreferences.microphonePreference
        recorder.onMeter = { [weak self] level in self?.persistMeter(level) }
        recorder.onMaximumDuration = { [weak self] in self?.requestFinish() }
        recorder.onInputRouteChanged = { [weak self] inputName in
            guard let self else { return }
            self.currentMicrophoneName = inputName
            if let inputName {
                self.lastMicrophoneName = inputName
                self.audioSessionAvailable = true
            }
        }
        recorder.onAudioSessionLifecycleEvent = { [weak self] event in
            self?.handleAudioSessionLifecycleEvent(event)
        }
        installDarwinObservers()
        loadGatewaySettings()
        refreshSetupStatus()
        DiagnosticLog.record(.appStarted)
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == AppConfiguration.urlScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "session" })?.value,
              let id = UUID(uuidString: value)
        else {
            message = "The keyboard sent an invalid recording request."
            return
        }
        switch url.host {
        case "dictate":
            if let requested = try? store.load(id) {
                activeRecord = requested
                // The hand-off can arrive after the keyboard already gave up on
                // it. Announcing a recording that `startSession` will decline to
                // start left the app insisting it was listening when it was not.
                if [.launchingApp, .awaitingReturn].contains(requested.state) {
                    message = "Starting the recording requested by the keyboard…"
                } else if requested.state == .expired {
                    message = "That dictation timed out. Tap Dictate again."
                }
            }
            Task { await startSession(id: id) }
        case "retry":
            retrySession(id: id)
        default:
            message = "The keyboard sent an unsupported action."
        }
    }

    func requestMicrophonePermission() {
        recorder.requestPermission { [weak self] granted in
            guard let self else { return }
            if granted {
                self.message = "Microphone permission granted."
                if KeyboardPreferences.quickDictationEnabled {
                    self.armQuickDictation()
                }
            } else {
                self.message = "Microphone permission denied."
            }
            self.refreshSetupStatus()
        }
    }

    func prepareQuickDictationIfEnabled() {
        debugQuickDictation(
            "prepare enabled=\(KeyboardPreferences.quickDictationEnabled) "
                + "permission=\(recorder.recordPermission.rawValue) "
                + "recording=\(recorder.isRecording)"
        )
        guard KeyboardPreferences.quickDictationEnabled,
              audioSessionAvailable,
              recorder.recordPermission == .granted,
              !recorder.isRecording,
              startingSessionID == nil
        else { return }
        armQuickDictation()
    }

    func setQuickDictationEnabled(_ enabled: Bool) {
        KeyboardPreferences.quickDictationEnabled = enabled
        if enabled {
            if recorder.recordPermission == .granted {
                armQuickDictation()
            } else {
                requestMicrophonePermission()
            }
        } else {
            stopQuickDictation()
        }
    }

    func stopQuickDictation() {
        KeyboardPreferences.quickDictationEnabled = false
        clearQuickDictationReadiness(deactivateAudioSession: true)
        message = "Quick Dictation is off. The keyboard will open vocaphone next time."
        DiagnosticLog.record(
            .quickDictationStopped,
            metadata: .reason(.userRequested)
        )
    }

    func updateGateway(baseURL: URL, token: String) {
        gatewayClient = GatewayClient(baseURL: baseURL, token: token)
    }

    /// A gateway configured last week may be unreachable today, so the setup
    /// checklist re-verifies rather than trusting the stored result.
    func refreshGatewayHealth() async {
        defer { refreshSetupStatus() }
        guard let value = UserDefaults.standard.string(forKey: "gatewayURL"),
              let baseURL = GatewayEndpoint.validatedURL(from: value),
              let token = try? KeychainStore.loadToken(),
              !token.isEmpty
        else {
            GatewayStatusPreferences.store(
                message: "Not tested",
                engine: "",
                ready: false
            )
            GatewayStatusPreferences.storeLanguageSupport(nil)
            GatewayStatusPreferences.storeStreamingSupport(nil, for: nil)
            return
        }
        let client = GatewayClient(baseURL: baseURL, token: token)
        do {
            try await client.verifyAuthentication()
            let health = try await client.health()
            gatewayClient = client
            GatewayStatusPreferences.store(
                message: health.engineReady
                    ? "Gateway, token, and model are ready."
                    : "Gateway reachable; model is not ready.",
                engine: health.engine.trimmingCharacters(in: .whitespacesAndNewlines),
                ready: health.engineReady
            )
            GatewayStatusPreferences.storeLanguageSupport(health)
            GatewayStatusPreferences.storeStreamingSupport(
                health.streamingSupported,
                for: baseURL
            )
        } catch let GatewayError.api(status, _) where status == 401 {
            GatewayStatusPreferences.store(
                message: "Gateway reachable, but the pairing token was rejected.",
                engine: "",
                ready: false
            )
            GatewayStatusPreferences.storeLanguageSupport(nil)
            GatewayStatusPreferences.storeStreamingSupport(nil, for: nil)
        } catch {
            GatewayStatusPreferences.store(
                message: "Gateway test failed: \(error.localizedDescription)",
                engine: "",
                ready: false
            )
            GatewayStatusPreferences.storeLanguageSupport(nil)
            GatewayStatusPreferences.storeStreamingSupport(nil, for: nil)
        }
    }

    func setMicrophonePreference(_ preference: MicrophonePreference) {
        guard !recorder.isRecording, startingSessionID == nil else {
            message = "Finish the current recording before changing microphones."
            return
        }
        let shouldRearmQuickDictation = recorder.isStandbyActive
        if shouldRearmQuickDictation {
            clearQuickDictationReadiness(deactivateAudioSession: true)
        }
        KeyboardPreferences.microphonePreference = preference
        recorder.microphonePreference = preference
        currentMicrophoneName = nil
        lastMicrophoneName = nil
        if shouldRearmQuickDictation {
            armQuickDictation()
        } else {
            message = "Microphone set to \(preference.displayName)."
        }
    }

    func startInAppTest() {
        guard !recorder.isRecording else { return }
        var record = SessionRecord(
            state: .idle,
            sourceDocumentID: "in-app-test",
            language: KeyboardPreferences.effectiveTranscriptionLanguage.rawValue,
            style: KeyboardPreferences.writingStyle.rawValue
        )
        do {
            try record.transition(to: .launchingApp)
            try store.save(record)
            activeRecord = record
            message = "Starting the iPhone microphone…"
            Task { await startSession(id: record.sessionID) }
        } catch {
            message = "Could not create the microphone test: \(error.localizedDescription)"
        }
    }

    func requestFinish() {
        guard var record = activeRecord, record.state == .recording else { return }
        DiagnosticLog.record(.finishRequested)
        do {
            try record.transition(to: .finalizing)
            try store.save(record)
            activeRecord = record
            liveActivity.update(status: "Finishing", canFinish: false)
            startPipeline(record)
        } catch {
            message = "Could not finish the recording."
        }
    }

    func cancel() {
        pipelineTask?.cancel()
        pipelineTask = nil
        pipelineSessionID = nil
        cancellationMonitorTask?.cancel()
        Task { await streamingBridge.cancel() }
        localSherpaSession?.cancel()
        localSherpaSession = nil
        guard var record = activeRecord else { return }
        let shouldRemainReady = shouldKeepQuickDictationReady(after: record)
        recorder.cancelSession(keepAudioSessionActive: shouldRemainReady)
        meterLevel = 0
        do {
            if !record.state.isTerminal {
                try record.transition(to: .canceled)
                try store.save(record)
            }
            activeRecord = record
            if shouldRemainReady {
                armQuickDictation()
                message = "Recording canceled. Quick Dictation is still ready."
            } else {
                clearQuickDictationReadiness(deactivateAudioSession: true)
                message = "Recording canceled."
            }
            liveActivity.end(status: "Canceled", dismissAfter: 0)
        } catch {
            message = "Could not cancel the session."
        }
        pollingTask?.cancel()
    }

    /// Housekeeping runs in the containing app rather than the extension, which
    /// has far less headroom for file work.
    nonisolated func pruneSharedStorage() {
        let store = SharedStore.shared
        Task.detached(priority: .utility) {
            try? store.pruneSessions()
            try? store.pruneOrphanedAudio()
        }
    }

    func recoverRecentSession() async {
        pruneSharedStorage()
        let recovered = try? store.mostRecent()
        // A Live Activity belongs to the system and outlives its app, so a
        // jetsam kill or a crash mid-recording strands one in the Dynamic
        // Island still offering Finish for a session that no longer exists.
        // Nothing else notices, because the process that owned it is gone.
        // Whether an activity is genuinely orphaned is the manager's own
        // question — a stale record still says `recording` in exactly the case
        // this is here to clean up, so it cannot be answered from one.
        liveActivity.discardOrphanedActivities()
        guard let record = recovered else {
            activeRecord = nil
            message = nil
            return
        }
        activeRecord = record
        guard !record.state.isTerminal else {
            switch record.state {
            case .completed:
                message = "The transcript was inserted successfully."
            case .canceled:
                message = "Recording canceled."
            case .expired:
                message = "The last dictation timed out and was discarded."
            default:
                message = record.error?.message
            }
            return
        }
        // Never against a capture this process is still making: the watchdog is
        // for a recorder that is gone, and the audio is the one thing here that
        // cannot be recreated.
        if !recorder.isRecording,
           let expired = SessionExpiryPolicy.expireIfStale(record, in: store)
        {
            activeRecord = expired
            message = "The last dictation timed out and was discarded."
            return
        }
        if [.launchingApp, .awaitingReturn].contains(record.state) {
            message = "Starting the recording requested by the keyboard…"
            await startSession(id: record.sessionID)
            return
        }
        if record.state == .targetContextChanged {
            message = "A transcript is waiting. Return to the field you dictated for."
            return
        }
        if record.canRetry {
            message = "A recording is preserved and ready to retry."
        }
    }

    private func startSession(id: UUID) async {
        guard startingSessionID == nil || startingSessionID == id else { return }
        guard startingSessionID != id else { return }
        startingSessionID = id
        defer { startingSessionID = nil }

        do {
            guard var record = try store.load(id) else {
                message = "The shared keyboard session was not found."
                return
            }
            guard [.launchingApp, .awaitingReturn].contains(record.state) else { return }
            // Claim the request before anything slow, so the keyboard's launch
            // fallback knows this app has it. Warming the microphone can take
            // seconds — a first on-device model load, another app releasing the
            // input — and without the claim the keyboard opens vocaphone on top
            // of a Quick Dictation that was seconds from recording.
            record.claimedAt = Date()
            try? store.save(record)
            clearQuickDictationMarker()
            activeRecord = record
            let granted = await withCheckedContinuation { continuation in
                recorder.requestPermission { continuation.resume(returning: $0) }
            }
            guard granted else {
                try record.transition(to: .permissionDenied)
                record.error = SessionFailure(
                    code: "microphone_permission_denied",
                    message: "Enable microphone access in Settings.",
                    recoverable: false
                )
                try store.save(record)
                activeRecord = record
                return
            }

            let directory = try localAudioDirectory()
            try await recorder.prepareForRecording()
            await soundFeedback.play(.start)
            guard let latestRecord = try store.load(id),
                  [.launchingApp, .awaitingReturn].contains(latestRecord.state)
            else {
                if KeyboardPreferences.quickDictationEnabled, audioSessionAvailable {
                    armQuickDictation()
                } else {
                    recorder.stopStandby(deactivateAudioSession: true)
                }
                return
            }
            record = latestRecord
            let shouldUseSherpaIncremental = LocalTranscriptionPreferences.enabled
                && LocalTranscriptionPreferences.modelIdentifier.flatMap {
                    LocalModelCatalog.descriptor(for: $0)?.engine == .sherpaOnnx
                } == true
            let audioURL = try recorder.start(
                sessionID: record.sessionID,
                directory: directory,
                includeLocalModelChunks: shouldUseSherpaIncremental
            )
            if shouldUseSherpaIncremental, let chunks = recorder.localPcmChunks {
                do {
                    localSherpaSession = try localModels.startSherpaIncrementalSession(
                        chunks: chunks,
                        language: record.language
                    )
                } catch {
                    // Keep the intact WAV fallback. The normal finish path will
                    // retry the same selected model in batch mode if preparing
                    // the incremental engine fails.
                    localSherpaSession = nil
                }
            }
            if let client = gatewayClient, let chunks = recorder.pcmChunks {
                if GatewayStatusPreferences.shouldAttemptStreaming(for: client.baseURL) {
                    await streamingBridge.start(
                        client: client,
                        sessionID: record.sessionID,
                        language: record.language,
                        style: record.style,
                        sampleRate: Int(recorder.transcriptionSampleRate),
                        chunks: chunks
                    )
                } else {
                    await streamingBridge.skipUnsupportedModel()
                }
            }
            if record.state == .launchingApp {
                try record.transition(to: .recording)
            } else if record.state == .awaitingReturn {
                try record.transition(to: .recording)
            }
            record.localAudioReference = audioURL.lastPathComponent
            try store.save(record)
            activeRecord = record
            message = record.startedInContainingApp == true
                ? "Recording. Tap Finish on the keyboard when you are done."
                : "Recording. Swipe back to the app where you want to type."
            if record.sourceDocumentID != "in-app-test" {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                liveActivity.start(sessionID: record.sessionID)
            } else {
                // The microphone test stays entirely inside the app and never
                // needs a Dynamic Island handoff.
                liveActivity.stopStandby()
            }
            beginPolling()
        } catch {
            recorder.cancelSession(keepAudioSessionActive: false)
            clearQuickDictationReadiness(deactivateAudioSession: true)
            if var failedRecord = try? store.load(id),
               [.launchingApp, .awaitingReturn].contains(failedRecord.state)
            {
                try? failedRecord.transition(to: .canceled)
                failedRecord.error = SessionFailure(
                    code: "recording_start_failed",
                    message: "The microphone could not start. Try dictating again.",
                    recoverable: false
                )
                try? store.save(failedRecord)
                activeRecord = failedRecord
            }
            DiagnosticLog.record(
                .operationFailed,
                metadata: .error(.recordingStartFailed)
            )
            message = "Recording could not start: \(error.localizedDescription)"
        }
    }

    private func retrySession(id: UUID) {
        guard let record = try? store.load(id),
              record.state == .uploading,
              record.localAudioReference != nil
        else {
            message = "The preserved recording is no longer retryable."
            return
        }
        activeRecord = record
        startPipeline(record)
    }

    private func startPipeline(_ record: SessionRecord) {
        guard pipelineSessionID != record.sessionID else { return }
        pipelineTask?.cancel()
        pipelineSessionID = record.sessionID
        pipelineTask = Task { [weak self] in
            await self?.finalizeAndTranscribe(record)
            guard let self, self.pipelineSessionID == record.sessionID else { return }
            self.pipelineSessionID = nil
            self.pipelineTask = nil
        }
    }

    private func beginPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let interval = SessionPollingPolicy.interval(for: self.activeRecord?.state)
                else { return }
                try? await Task.sleep(for: .milliseconds(Int(interval * 1_000)))
                guard !Task.isCancelled else { return }
                await self.handleSharedStateSignal()
            }
        }
    }

    private func finalizeAndTranscribe(_ incoming: SessionRecord) async {
        pollingTask?.cancel()
        beginCancellationMonitoring(sessionID: incoming.sessionID)
        defer { cancellationMonitorTask?.cancel() }
        var record = incoming
        let shouldRemainReady = shouldKeepQuickDictationReady(after: record)
        let wasRecording = recorder.isRecording
        let output = recorder.stopSession(
            keepAudioSessionActive: true
        ) ?? resolvedAudioURL(for: record)
        DiagnosticLog.record(.captureStopped)
        if wasRecording {
            // Feedback is optional and should never sit in front of gateway work.
            Task { await soundFeedback.play(.stop) }
        }
        meterLevel = 0
        if shouldRemainReady {
            armQuickDictation()
        } else {
            clearQuickDictationReadiness(deactivateAudioSession: true)
        }
        guard let output, FileManager.default.fileExists(atPath: output.path) else {
            await fail(
                &record,
                state: .uploadFailedRecoverable,
                code: "audio_missing",
                message: "The recording file is missing."
            )
            return
        }

        // A recording of digital silence is what iOS hands an app whose
        // microphone another app took mid-session. Transcribing it would spend
        // the whole wait to report an empty transcript, which tells the user
        // nothing they can act on.
        if wasRecording, recorder.lastPeakLevel <= CaptureFormat.silenceThreshold {
            await streamingBridge.cancel()
            try? FileManager.default.removeItem(at: output)
            await fail(
                &record,
                state: .transcriptionFailedPermanent,
                code: "microphone_silenced",
                message: "Another app or a call was using the microphone, so only "
                    + "silence was recorded. Try again once it has finished.",
                recoverable: false
            )
            return
        }

        // Local inference deliberately happens before the gateway guard. A
        // device configured for on-device transcription must still work with no
        // gateway URL, token, network, or server health result at all.
        if LocalTranscriptionPreferences.enabled {
            await streamingBridge.cancel()
            await finalizeLocally(&record, audioURL: output)
            return
        }

        guard let client = gatewayClient else {
            await streamingBridge.cancel()
            await fail(
                &record,
                state: .serverUnavailable,
                code: "gateway_not_configured",
                message: "Configure and test the transcription gateway in vocaphone."
            )
            return
        }

        do {
            if record.state == .finalizing || record.canRetry {
                try record.transition(to: .uploading)
            }
            try store.save(record)
            activeRecord = record
            message = "Finishing on your gateway…"
            liveActivity.update(status: "Finishing transcript", canFinish: false)

            if let transcript = await streamingBridge.finish(
                droppedChunks: recorder.lastDroppedChunkCount
            ) {
                record.transcript = transcript
                record.error = nil
                try record.transition(to: .readyToInsert)
                try store.save(record)
                activeRecord = record
                DiagnosticLog.record(.transcriptReady)
                UserDefaults.standard.set(
                    "Gateway and streaming model are ready.",
                    forKey: GatewayStatusPreferences.healthMessageKey
                )
                try? FileManager.default.removeItem(at: output)
                markTranscriptDelivered(for: record)
                liveActivity.end(status: "Transcript ready")
                return
            }

            message = "Uploading to your gateway…"
            liveActivity.update(status: "Sending to gateway", canFinish: false)

            let created = try await client.createSession(
                id: record.sessionID,
                language: record.language,
                style: record.style
            )
            record.serverJobID = created.jobID
            DiagnosticLog.record(.uploadStarted)
            _ = try await client.uploadAudio(sessionID: record.sessionID, fileURL: output)
            DiagnosticLog.record(.uploadCompleted)
            try record.transition(to: .transcribing)
            try store.save(record)
            activeRecord = record
            message = "Transcribing on your gateway…"
            liveActivity.update(status: "Transcribing", canFinish: false)

            DiagnosticLog.record(.transcriptionStarted)
            let finished = try await client.finish(sessionID: record.sessionID)
            guard let transcript = finished.transcript, !transcript.isEmpty else {
                throw GatewayError.api(status: 500, code: finished.errorCode ?? "empty_transcript")
            }
            record.transcript = transcript
            record.error = nil
            try record.transition(to: .readyToInsert)
            try store.save(record)
            activeRecord = record
            DiagnosticLog.record(.transcriptReady)
            UserDefaults.standard.set(
                "Gateway and model are ready.",
                forKey: GatewayStatusPreferences.healthMessageKey
            )
            try? FileManager.default.removeItem(at: output)
            markTranscriptDelivered(for: record)
            liveActivity.end(status: "Transcript ready")
        } catch {
            if Task.isCancelled || error is CancellationError {
                return
            }
            let code = redactedErrorCode(error)
            // The gateway's model cannot transcribe the chosen language. Retrying
            // replays the same pairing, so this fails permanently and says what to
            // change instead of promising a retry that cannot succeed.
            if code == "language_unsupported" {
                await fail(
                    &record,
                    state: .transcriptionFailedPermanent,
                    code: code,
                    message: "Your gateway's model does not support this language. "
                        + "Choose Automatic or another language in Settings.",
                    recoverable: false
                )
                return
            }
            let state: SessionState
            if error is URLError {
                state = .serverUnavailable
            } else if record.state == .uploading {
                state = .uploadFailedRecoverable
            } else {
                state = .transcriptionFailedRecoverable
            }
            await fail(
                &record,
                state: state,
                code: code,
                message: "The recording is preserved. Return to the keyboard to retry."
            )
        }
    }

    private func finalizeLocally(_ record: inout SessionRecord, audioURL: URL) async {
        do {
            if record.state == .finalizing || record.canRetry {
                try record.transition(to: .uploading)
            }
            try store.save(record)
            activeRecord = record
            message = "Transcribing on this iPhone…"
            liveActivity.update(status: "Transcribing on device", canFinish: false)
            try record.transition(to: .transcribing)
            try store.save(record)
            activeRecord = record

            let incremental = localSherpaSession
            localSherpaSession = nil
            let text: String
            if let incremental {
                let incrementalText = await incremental.finish()
                if incrementalText.isEmpty {
                    // A model can still produce no tokens for a boundary split;
                    // preserve the old whole-file retry as a last resort.
                    text = try await localModels.transcribe(
                        audioURL: audioURL,
                        language: record.language
                    )
                } else {
                    text = incrementalText
                }
            } else {
                text = try await localModels.transcribe(
                    audioURL: audioURL,
                    language: record.language
                )
            }
            record.transcript = TranscriptStyler.apply(
                text,
                style: WritingStyle(rawValue: record.style) ?? .casual,
                language: record.language
            )
            record.error = nil
            try record.transition(to: .readyToInsert)
            try store.save(record)
            activeRecord = record
            DiagnosticLog.record(.transcriptReady)
            try? FileManager.default.removeItem(at: audioURL)
            markTranscriptDelivered(for: record)
            liveActivity.end(status: "Transcript ready")
            message = "Transcribed privately on this iPhone."
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            await fail(
                &record,
                state: .transcriptionFailedRecoverable,
                code: "local_transcription_failed",
                message: "On-device transcription failed. The recording is preserved; retry after checking the selected model."
            )
        }
    }

    private func beginCancellationMonitoring(sessionID: UUID) {
        cancellationMonitorTask?.cancel()
        cancellationMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard let self,
                      let record = try? self.store.load(sessionID)
                else { continue }
                if record.state == .canceled {
                    self.pipelineTask?.cancel()
                    return
                }
            }
        }
    }

    private func fail(
        _ record: inout SessionRecord,
        state: SessionState,
        code: String,
        message failureMessage: String,
        recoverable: Bool = true
    ) async {
        DiagnosticLog.record(
            .operationFailed,
            metadata: .error(diagnosticErrorCode(for: code, state: state))
        )
        do {
            try record.transition(to: state)
            record.error = SessionFailure(code: code, message: failureMessage, recoverable: recoverable)
            try store.save(record)
            activeRecord = record
            message = failureMessage
            liveActivity.end(status: "Needs attention", dismissAfter: 5)
            beginPolling()
        } catch {
            message = "The session failed and its state could not be saved."
        }
    }

    /// The first transcript to come back is the only proof that recording,
    /// upload and transcription work together, so guided setup stops asking for
    /// a trial run once one has arrived.
    private func markTranscriptDelivered(for record: SessionRecord) {
        KeyboardPreferences.hasCompletedFirstDictation = true
        refreshSetupStatus()
        message = record.sourceDocumentID == "in-app-test"
            ? "Transcript ready. Your gateway is working end to end."
            : "Transcript ready. Return to the keyboard to insert it."
    }

    private func persistMeter(_ level: Float) {
        guard let record = activeRecord, record.state == .recording else { return }
        let clamped = min(max(level, 0), 1)
        // Only the level changes here. Leaving `activeRecord` untouched keeps
        // this from invalidating every view observing the session.
        meterLevel = clamped
        // Meter updates are intentionally stored separately from the session
        // record. Otherwise a stale meter write from the app can overwrite a
        // finalizing/canceled state written by the keyboard extension.
        try? store.saveMeter(clamped, for: record.sessionID)
    }

    private func shouldKeepQuickDictationReady(after record: SessionRecord) -> Bool {
        KeyboardPreferences.quickDictationEnabled
            && audioSessionAvailable
            && record.sourceDocumentID != "in-app-test"
    }

    private func armQuickDictation() {
        guard KeyboardPreferences.quickDictationEnabled,
              audioSessionAvailable,
              !recorder.isRecording
        else { return }

        clearQuickDictationMarker()
        do {
            try recorder.startStandby()
            let activatedAt = Date()
            let availability = QuickDictationAvailability(
                activatedAt: activatedAt,
                expiresAt: activatedAt.addingTimeInterval(
                    AppConfiguration.quickDictationWindowSeconds
                )
            )
            try store.saveQuickDictationAvailability(availability)
            quickDictationExpiresAt = availability.expiresAt
            beginQuickDictationWatcher(availability)
            liveActivity.startStandby(expiresAt: availability.expiresAt)
            DiagnosticLog.record(.quickDictationArmed)
            debugQuickDictation("armed until \(availability.expiresAt)")
        } catch {
            DiagnosticLog.record(
                .operationFailed,
                metadata: .error(.quickDictationArmFailed)
            )
            debugQuickDictation("arming failed: \(error.localizedDescription)")
            clearQuickDictationReadiness(deactivateAudioSession: true)
            message = "Quick Dictation could not stay ready: \(error.localizedDescription)"
        }
    }

    private func beginQuickDictationWatcher(_ availability: QuickDictationAvailability) {
        quickDictationWatcherTask?.cancel()
        quickDictationWatcherTask = Task { [weak self] in
            var refreshedAvailability = availability
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard refreshedAvailability.expiresAt > Date(),
                      self.recorder.isStandbyActive,
                      self.audioSessionAvailable
                else {
                    self.clearQuickDictationReadiness(deactivateAudioSession: true)
                    return
                }
                refreshedAvailability = refreshedAvailability.refreshingHeartbeat()
                do {
                    try self.store.saveQuickDictationAvailability(
                        refreshedAvailability,
                        notifyObservers: false
                    )
                } catch {
                    self.clearQuickDictationReadiness(deactivateAudioSession: true)
                    return
                }
                await self.startPendingQuickDictationIfNeeded(
                    availability: refreshedAvailability
                )
            }
        }
    }

    private func clearQuickDictationReadiness(deactivateAudioSession: Bool) {
        clearQuickDictationMarker()
        recorder.stopStandby(deactivateAudioSession: deactivateAudioSession)
        liveActivity.stopStandby()
    }

    private func clearQuickDictationMarker() {
        quickDictationWatcherTask?.cancel()
        quickDictationWatcherTask = nil
        quickDictationExpiresAt = nil
        try? store.clearQuickDictationAvailability()
    }

    private func localAudioDirectory() throws -> URL {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        ) else {
            throw SharedStoreError.appGroupUnavailable
        }
        return group.appendingPathComponent("pending-audio", isDirectory: true)
    }

    private func resolvedAudioURL(for record: SessionRecord) -> URL? {
        guard let reference = record.localAudioReference,
              !reference.contains("/"),
              let directory = try? localAudioDirectory()
        else { return nil }
        return directory.appendingPathComponent(reference)
    }

    private func installDarwinObservers() {
        darwinObservations.append(
            VocaPhoneDarwinCenter.observe(.sessionChanged) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleSharedStateSignal()
                }
            }
        )
        darwinObservations.append(
            VocaPhoneDarwinCenter.observe(.keyboardStatusChanged) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refreshSetupStatus()
                }
            }
        )
        darwinObservations.append(
            VocaPhoneDarwinCenter.observe(.stopQuickDictationRequested) { [weak self] in
                Task { @MainActor [weak self] in
                    DiagnosticLog.record(.stopQuickDictationRequested)
                    self?.stopQuickDictation()
                }
            }
        )
    }

    /// Fast path for keyboard and Live Activity writes. Adaptive polling remains
    /// as recovery if iOS drops a Darwin notification or recreates one process
    /// between the durable write and its signal.
    private func handleSharedStateSignal() async {
        guard let current = activeRecord, !current.state.isTerminal else {
            await startPendingQuickDictationIfNeeded()
            return
        }
        guard let shared = try? store.load(current.sessionID) else { return }
        if shared != current { activeRecord = shared }

        switch shared.state {
        case .finalizing:
            liveActivity.update(status: "Finishing", canFinish: false)
            startPipeline(shared)
        case .uploading where !recorder.isRecording && pipelineSessionID == nil:
            startPipeline(shared)
        // Expiry is the keyboard acting as watchdog for an app that stopped
        // answering. It has to tear down exactly as far as a cancel does:
        // retiring only the record would leave this recorder holding the
        // microphone for a session no other process believes in.
        case .canceled, .expired:
            pipelineTask?.cancel()
            pipelineTask = nil
            pipelineSessionID = nil
            await streamingBridge.cancel()
            localSherpaSession?.cancel()
            localSherpaSession = nil
            let shouldRemainReady = shouldKeepQuickDictationReady(after: shared)
            recorder.cancelSession(keepAudioSessionActive: shouldRemainReady)
            let headline = shared.state == .expired
                ? "The dictation timed out and was discarded."
                : "Recording canceled."
            if shouldRemainReady {
                armQuickDictation()
                message = headline + " Quick Dictation is still ready."
            } else {
                clearQuickDictationReadiness(deactivateAudioSession: true)
                message = headline
            }
            liveActivity.end(
                status: shared.state == .expired ? "Timed out" : "Canceled",
                dismissAfter: 0
            )
            await startPendingQuickDictationIfNeeded()
        default:
            if shared.state.isTerminal {
                await startPendingQuickDictationIfNeeded()
            }
        }
    }

    private func startPendingQuickDictationIfNeeded(
        availability suppliedAvailability: QuickDictationAvailability? = nil
    ) async {
        guard recorder.isStandbyActive, audioSessionAvailable else { return }
        let availability = suppliedAvailability
            ?? (try? store.loadQuickDictationAvailability())
        guard let availability, availability.isReady() else { return }
        guard let pending = try? store.recent(limit: 8).first(where: {
            [.launchingApp, .awaitingReturn].contains($0.state)
                && availability.acceptsRequest(createdAt: $0.createdAt)
        }) else { return }
        await startSession(id: pending.sessionID)
    }

    private func handleAudioSessionLifecycleEvent(_ event: AudioSessionLifecycleEvent) {
        switch event {
        case .interruptionBegan:
            DiagnosticLog.record(.audioInterruptionBegan)
            handleAudioLoss(reason: "Audio was interrupted. Finishing what was captured.")
        case let .interruptionEnded(shouldResume):
            audioLifecycleGeneration &+= 1
            audioSessionAvailable = true
            DiagnosticLog.record(
                .audioInterruptionEnded,
                metadata: .reason(shouldResume ? .resumeAllowed : .resumeNotAllowed)
            )
            if shouldResume,
               KeyboardPreferences.containingAppIsForeground,
               KeyboardPreferences.quickDictationEnabled
            {
                prepareQuickDictationIfEnabled()
            }
        case .mediaServicesReset:
            DiagnosticLog.record(.audioMediaServicesReset)
            handleAudioLoss(reason: "iPhone audio restarted. Finishing what was captured.")
            let recoveryGeneration = audioLifecycleGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self,
                      self.audioLifecycleGeneration == recoveryGeneration
                else { return }
                self.audioSessionAvailable = true
                if KeyboardPreferences.containingAppIsForeground,
                   KeyboardPreferences.quickDictationEnabled
                {
                    self.prepareQuickDictationIfEnabled()
                }
            }
        case .inputUnavailable:
            DiagnosticLog.record(.audioInputUnavailable)
            handleAudioLoss(reason: "The microphone input became unavailable.")
        }
    }

    private func handleAudioLoss(reason: String) {
        audioLifecycleGeneration &+= 1
        audioSessionAvailable = false
        if activeRecord?.state == .recording, recorder.isRecording {
            message = reason
            // Ending the activity here retired the manager's session, which
            // then silently dropped every later update: the Dynamic Island
            // disappeared the instant a call arrived, while the app went on to
            // transcribe what it had already captured, and the transcript
            // arrived with nothing outside the app to say so. What was captured
            // is still being finished, so the activity follows it there.
            liveActivity.update(status: "Audio interrupted", canFinish: false)
            requestFinish()
        } else {
            clearQuickDictationReadiness(deactivateAudioSession: true)
            message = reason
        }
    }

    private func loadGatewaySettings() {
        guard let value = UserDefaults.standard.string(forKey: "gatewayURL"),
              let baseURL = GatewayEndpoint.validatedURL(from: value),
              let token = try? KeychainStore.loadToken(),
              !token.isEmpty
        else { return }
        gatewayClient = GatewayClient(baseURL: baseURL, token: token)
    }

    private func redactedErrorCode(_ error: Error) -> String {
        if let gateway = error as? GatewayError {
            switch gateway {
            case .invalidResponse: return "invalid_gateway_response"
            case let .api(_, code): return code
            }
        }
        if error is URLError { return "server_unavailable" }
        return "transcription_failed"
    }

    private func diagnosticErrorCode(
        for code: String,
        state: SessionState
    ) -> DiagnosticErrorCode {
        switch code {
        case "audio_missing": .audioMissing
        case "gateway_not_configured": .gatewayNotConfigured
        case "microphone_permission_denied": .microphonePermissionDenied
        case "microphone_silenced": .microphoneSilenced
        case "language_unsupported": .languageUnsupported
        case "server_unavailable": .serverUnavailable
        default:
            state == .uploadFailedRecoverable ? .uploadFailed : .transcriptionFailed
        }
    }

    private func debugQuickDictation(_ value: String) {
#if DEBUG
        print("[QuickDictation] \(value)")
#endif
    }
}

/// Forwards captured audio to the gateway over a WebSocket.
///
/// The capture pipeline already emits chunks in order on a single queue, so a
/// lone consumer task preserves ordering without a reordering buffer. Memory is
/// bounded by the `AsyncStream` the recorder hands over: when the link cannot
/// keep up, chunks are dropped and the recorder reports it, and the caller
/// falls back to uploading the intact file rather than the stream growing
/// without limit.
private actor StreamingAudioBridge {
    private var stream: GatewayAudioStream?
    private var pump: Task<Void, Never>?
    private var failed = false
    private var ready = false
    private var fallbackRecorded = false

    func start(
        client: GatewayClient,
        sessionID: UUID,
        language: String,
        style: String,
        sampleRate: Int,
        chunks: AsyncStream<Data>
    ) {
        cancel()
        failed = false
        DiagnosticLog.record(.streamHandshakeStarted)
        pump = Task { [weak self] in
            let opened: GatewayAudioStream
            do {
                opened = try await client.startAudioStream(
                    sessionID: sessionID,
                    language: language,
                    style: style,
                    sampleRate: sampleRate
                )
            } catch {
                guard !Task.isCancelled else { return }
                await self?.recordFallbackIfNeeded()
                return
            }
            guard !Task.isCancelled else {
                opened.cancel()
                return
            }
            await self?.attach(opened)
            DiagnosticLog.record(.streamReady)
            for await chunk in chunks {
                guard !Task.isCancelled else { break }
                await self?.deliver(chunk)
            }
        }
    }

    func skipUnsupportedModel() {
        cancel()
        recordFallbackIfNeeded()
    }

    /// Returns a transcript only when the whole recording reached the gateway.
    /// Any loss makes the stream untrustworthy, so the caller uploads instead.
    func finish(droppedChunks: Int) async -> String? {
        guard droppedChunks == 0 else {
            cancelPendingNegotiation()
            recordFallbackIfNeeded()
            return nil
        }
        guard ready else {
            cancelPendingNegotiation()
            recordFallbackIfNeeded()
            return nil
        }
        // The recorder finished the chunk stream before calling this, so the
        // pump terminates once it has drained what is still buffered.
        await pump?.value
        pump = nil
        guard !failed, let stream else {
            stream?.cancel()
            self.stream = nil
            ready = false
            recordFallbackIfNeeded()
            return nil
        }
        self.stream = nil
        ready = false
        do {
            DiagnosticLog.record(.transcriptionStarted)
            return try await stream.finish()
        } catch {
            stream.cancel()
            recordFallbackIfNeeded()
            return nil
        }
    }

    func cancel() {
        pump?.cancel()
        pump = nil
        stream?.cancel()
        stream = nil
        failed = false
        ready = false
        fallbackRecorded = false
    }

    private func cancelPendingNegotiation() {
        pump?.cancel()
        pump = nil
        stream?.cancel()
        stream = nil
        failed = false
        ready = false
    }

    private func attach(_ opened: GatewayAudioStream) {
        stream = opened
        ready = true
    }

    private func recordFallbackIfNeeded() {
        guard !fallbackRecorded else { return }
        fallbackRecorded = true
        DiagnosticLog.record(.batchFallback)
    }

    private func deliver(_ chunk: Data) async {
        guard !failed, let stream else { return }
        do {
            try await stream.send(chunk)
        } catch {
            failed = true
            stream.cancel()
            self.stream = nil
        }
    }
}
