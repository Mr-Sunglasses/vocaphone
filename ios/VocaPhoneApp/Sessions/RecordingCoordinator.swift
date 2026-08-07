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
    private var cancellationMonitorTask: Task<Void, Never>?
    private var quickDictationWatcherTask: Task<Void, Never>?
    private var startingSessionID: UUID?
    private var gatewayClient: GatewayClient?
    private var lastMicrophoneName: String?
    private let liveActivity = LiveActivityManager.shared
    private let streamingBridge = StreamingAudioBridge()

    var stateLabel: String { activeRecord?.state.rawValue ?? "idle" }
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
        let refreshed = SetupStatus(
            gatewayReady: UserDefaults.standard.bool(
                forKey: GatewayStatusPreferences.engineReadyKey
            ),
            gatewayAddress: address,
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
            }
        }
        loadGatewaySettings()
        refreshSetupStatus()
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
                message = "Starting the recording requested by the keyboard…"
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
        } catch let GatewayError.api(status, _) where status == 401 {
            GatewayStatusPreferences.store(
                message: "Gateway reachable, but the pairing token was rejected.",
                engine: "",
                ready: false
            )
            GatewayStatusPreferences.storeLanguageSupport(nil)
        } catch {
            GatewayStatusPreferences.store(
                message: "Gateway test failed: \(error.localizedDescription)",
                engine: "",
                ready: false
            )
            GatewayStatusPreferences.storeLanguageSupport(nil)
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
        cancellationMonitorTask?.cancel()
        Task { await streamingBridge.cancel() }
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
            liveActivity.end(status: "Canceled", dismissAfter: 0)
            if shouldRemainReady {
                armQuickDictation()
                message = "Recording canceled. Quick Dictation is still ready."
            } else {
                clearQuickDictationReadiness(deactivateAudioSession: true)
                message = "Recording canceled."
            }
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
        guard let record = try? store.mostRecent() else {
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
            default:
                message = record.error?.message
            }
            return
        }
        if [.launchingApp, .awaitingReturn].contains(record.state),
           Date().timeIntervalSince(record.updatedAt) <= 120
        {
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
            let audioURL = try recorder.start(sessionID: record.sessionID, directory: directory)
            if let client = gatewayClient, let chunks = recorder.pcmChunks {
                await streamingBridge.start(
                    client: client,
                    sessionID: record.sessionID,
                    language: record.language,
                    style: record.style,
                    sampleRate: Int(recorder.transcriptionSampleRate),
                    chunks: chunks
                )
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
            }
            beginPolling()
        } catch {
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
        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            await self?.finalizeAndTranscribe(record)
        }
    }

    private func beginPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let current = self.activeRecord,
                      let shared = try? self.store.load(current.sessionID)
                else { continue }
                // Four times a second the record is usually identical. Assigning
                // it anyway would invalidate observers for no reason.
                if shared != current {
                    self.activeRecord = shared
                }
                switch shared.state {
                case .finalizing:
                    self.liveActivity.update(status: "Finishing", canFinish: false)
                    self.startPipeline(shared)
                    return
                case .uploading where !self.recorder.isRecording:
                    self.startPipeline(shared)
                    return
                case .canceled:
                    let shouldRemainReady = self.shouldKeepQuickDictationReady(after: shared)
                    self.recorder.cancelSession(keepAudioSessionActive: shouldRemainReady)
                    if shouldRemainReady {
                        self.armQuickDictation()
                        self.message = "Recording canceled. Quick Dictation is still ready."
                    } else {
                        self.clearQuickDictationReadiness(deactivateAudioSession: true)
                        self.message = "Recording canceled."
                    }
                    self.liveActivity.end(status: "Canceled", dismissAfter: 0)
                    return
                default:
                    continue
                }
            }
        }
    }

    private func finalizeAndTranscribe(_ incoming: SessionRecord) async {
        pollingTask?.cancel()
        beginCancellationMonitoring(sessionID: incoming.sessionID)
        defer { cancellationMonitorTask?.cancel() }
        var record = incoming
        let shouldRemainReady = shouldKeepQuickDictationReady(after: record)
        let output = recorder.stopSession(
            keepAudioSessionActive: shouldRemainReady
        ) ?? resolvedAudioURL(for: record)
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
            _ = try await client.uploadAudio(sessionID: record.sessionID, fileURL: output)
            try record.transition(to: .transcribing)
            try store.save(record)
            activeRecord = record
            message = "Transcribing on your gateway…"
            liveActivity.update(status: "Transcribing", canFinish: false)

            let finished = try await client.finish(sessionID: record.sessionID)
            guard let transcript = finished.transcript, !transcript.isEmpty else {
                throw GatewayError.api(status: 500, code: finished.errorCode ?? "empty_transcript")
            }
            record.transcript = transcript
            record.error = nil
            try record.transition(to: .readyToInsert)
            try store.save(record)
            activeRecord = record
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

    private func beginCancellationMonitoring(sessionID: UUID) {
        cancellationMonitorTask?.cancel()
        cancellationMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
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
            && record.sourceDocumentID != "in-app-test"
    }

    private func armQuickDictation() {
        guard KeyboardPreferences.quickDictationEnabled,
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
            debugQuickDictation("armed until \(availability.expiresAt)")
        } catch {
            debugQuickDictation("arming failed: \(error.localizedDescription)")
            clearQuickDictationReadiness(deactivateAudioSession: true)
            message = "Quick Dictation could not stay ready: \(error.localizedDescription)"
        }
    }

    private func beginQuickDictationWatcher(_ availability: QuickDictationAvailability) {
        quickDictationWatcherTask?.cancel()
        quickDictationWatcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                guard availability.isReady(), self.recorder.isStandbyActive else {
                    self.clearQuickDictationReadiness(deactivateAudioSession: true)
                    return
                }
                guard let pending = try? self.store.recent(limit: 8).first(where: {
                    [.launchingApp, .awaitingReturn].contains($0.state)
                        && $0.createdAt >= availability.activatedAt
                        && $0.createdAt < availability.expiresAt
                }) else { continue }

                await self.startSession(id: pending.sessionID)
                return
            }
        }
    }

    private func clearQuickDictationReadiness(deactivateAudioSession: Bool) {
        clearQuickDictationMarker()
        recorder.stopStandby(deactivateAudioSession: deactivateAudioSession)
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

    func start(
        client: GatewayClient,
        sessionID: UUID,
        language: String,
        style: String,
        sampleRate: Int,
        chunks: AsyncStream<Data>
    ) async {
        cancel()
        guard let opened = try? await client.startAudioStream(
            sessionID: sessionID,
            language: language,
            style: style,
            sampleRate: sampleRate
        ) else { return }

        stream = opened
        failed = false
        pump = Task { [weak self] in
            for await chunk in chunks {
                await self?.deliver(chunk)
            }
        }
    }

    /// Returns a transcript only when the whole recording reached the gateway.
    /// Any loss makes the stream untrustworthy, so the caller uploads instead.
    func finish(droppedChunks: Int) async -> String? {
        // The recorder finished the chunk stream before calling this, so the
        // pump terminates once it has drained what is still buffered.
        await pump?.value
        pump = nil
        guard droppedChunks == 0, !failed, let stream else {
            cancel()
            return nil
        }
        self.stream = nil
        do {
            return try await stream.finish()
        } catch {
            stream.cancel()
            return nil
        }
    }

    func cancel() {
        pump?.cancel()
        pump = nil
        stream?.cancel()
        stream = nil
        failed = false
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
