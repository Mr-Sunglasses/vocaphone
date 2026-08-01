import Foundation
import SwiftUI
import UIKit

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var activeRecord: SessionRecord?
    @Published private(set) var message: String?
    @Published private(set) var quickDictationExpiresAt: Date?
    @Published private(set) var currentMicrophoneName: String?

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
    var meterLevel: Float { activeRecord?.meterLevel ?? 0 }
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

    /// Dictation aimed at Local Flow's own text field. The keyboard stays on
    /// screen, so the transcript lands without any app switch.
    var isDictatingIntoContainingApp: Bool {
        isRecording && activeRecord?.startedInContainingApp == true
    }
    var canChangeMicrophone: Bool {
        !recorder.isRecording && startingSessionID == nil
    }
    var microphonePermissionGranted: Bool {
        recorder.recordPermission == .granted
    }

    /// Setup progress the app cannot otherwise observe: iOS exposes no API for
    /// whether a keyboard extension is installed.
    func keyboardStatus() -> KeyboardStatus? {
        try? store.loadKeyboardStatus()
    }

    func recentTranscripts(limit: Int = 50) -> [SessionRecord] {
        ((try? store.recent(limit: limit)) ?? [])
            .filter { !($0.transcript ?? "").isEmpty }
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
        let streamingBridge = streamingBridge
        recorder.onPCMChunk = { data, sequence in
            Task { await streamingBridge.send(data, sequence: sequence) }
        }
        loadGatewaySettings()
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
        message = "Quick Dictation is off. The keyboard will open Local Flow next time."
    }

    func updateGateway(baseURL: URL, token: String) {
        gatewayClient = GatewayClient(baseURL: baseURL, token: token)
    }

    /// A gateway configured last week may be unreachable today, so the setup
    /// checklist re-verifies rather than trusting the stored result.
    func refreshGatewayHealth() async {
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
        } catch let GatewayError.api(status, _) where status == 401 {
            GatewayStatusPreferences.store(
                message: "Gateway reachable, but the pairing token was rejected.",
                engine: "",
                ready: false
            )
        } catch {
            GatewayStatusPreferences.store(
                message: "Gateway test failed: \(error.localizedDescription)",
                engine: "",
                ready: false
            )
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
            language: "auto",
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
            if let client = gatewayClient, let sampleRate = recorder.recordingSampleRate {
                await streamingBridge.start(
                    client: client,
                    sessionID: record.sessionID,
                    language: record.language,
                    style: record.style,
                    sampleRate: Int(sampleRate.rounded())
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
                self.activeRecord = shared
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
                message: "Configure and test the transcription gateway in Local Flow."
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
                expectedChunks: recorder.lastFinishedChunkCount
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
                message = "Transcript ready. Return to the keyboard to insert it."
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
            message = "Transcript ready. Return to the keyboard to insert it."
            liveActivity.end(status: "Transcript ready")
        } catch {
            if Task.isCancelled || error is CancellationError {
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
                code: redactedErrorCode(error),
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
        message failureMessage: String
    ) async {
        do {
            try record.transition(to: state)
            record.error = SessionFailure(code: code, message: failureMessage, recoverable: true)
            try store.save(record)
            activeRecord = record
            message = failureMessage
            liveActivity.end(status: "Needs attention", dismissAfter: 5)
            beginPolling()
        } catch {
            message = "The session failed and its state could not be saved."
        }
    }

    private func persistMeter(_ level: Float) {
        guard var record = activeRecord, record.state == .recording else { return }
        record.meterLevel = min(max(level, 0), 1)
        activeRecord = record
        // Meter updates are intentionally stored separately from the session
        // record. Otherwise a stale meter write from the app can overwrite a
        // finalizing/canceled state written by the keyboard extension.
        try? store.saveMeter(level, for: record.sessionID)
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

private actor StreamingAudioBridge {
    private var stream: GatewayAudioStream?
    private var pending: [UInt64: Data] = [:]
    private var nextSequence: UInt64 = 0
    private var acceptingAudio = false

    func start(
        client: GatewayClient,
        sessionID: UUID,
        language: String,
        style: String,
        sampleRate: Int
    ) async {
        stream?.cancel()
        pending.removeAll(keepingCapacity: true)
        nextSequence = 0
        acceptingAudio = true
        stream = try? await client.startAudioStream(
            sessionID: sessionID,
            language: language,
            style: style,
            sampleRate: sampleRate
        )
        if stream == nil {
            acceptingAudio = false
            pending.removeAll()
        } else {
            await drainPending()
        }
    }

    func send(_ data: Data, sequence: UInt64) async {
        guard acceptingAudio else { return }
        pending[sequence] = data
        await drainPending()
    }

    func finish(expectedChunks: UInt64) async -> String? {
        for _ in 0..<100 where nextSequence < expectedChunks && acceptingAudio {
            await drainPending()
            if nextSequence < expectedChunks {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        guard nextSequence == expectedChunks else {
            cancel()
            return nil
        }
        guard let stream else { return nil }
        acceptingAudio = false
        self.stream = nil
        do {
            return try await stream.finish()
        } catch {
            stream.cancel()
            return nil
        }
    }

    func cancel() {
        stream?.cancel()
        stream = nil
        acceptingAudio = false
        pending.removeAll()
    }

    private func drainPending() async {
        guard let stream else { return }
        while let data = pending.removeValue(forKey: nextSequence) {
            do {
                try await stream.send(data)
                nextSequence += 1
            } catch {
                stream.cancel()
                self.stream = nil
                acceptingAudio = false
                pending.removeAll()
                return
            }
        }
    }
}
