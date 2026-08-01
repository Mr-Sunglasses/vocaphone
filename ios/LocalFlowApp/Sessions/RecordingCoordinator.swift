import Foundation
import SwiftUI
import UIKit

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var activeRecord: SessionRecord?
    @Published private(set) var message: String?
    @Published private(set) var quickDictationExpiresAt: Date?

    private let recorder = AudioRecorder()
    private let store = SharedStore.shared
    private var pollingTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var cancellationMonitorTask: Task<Void, Never>?
    private var quickDictationWatcherTask: Task<Void, Never>?
    private var startingSessionID: UUID?
    private var gatewayClient: GatewayClient?
    private let liveActivity = LiveActivityManager.shared

    var stateLabel: String { activeRecord?.state.rawValue ?? "idle" }
    var isRecording: Bool { activeRecord?.state == .recording && recorder.isRecording }
    var meterLevel: Float { activeRecord?.meterLevel ?? 0 }
    var hasError: Bool { activeRecord?.error != nil }
    var transcript: String? { activeRecord?.transcript }
    var isQuickDictationReady: Bool {
        guard let quickDictationExpiresAt else { return false }
        return recorder.isStandbyActive && quickDictationExpiresAt > Date()
    }
    var isKeyboardRecording: Bool {
        isRecording && activeRecord?.sourceDocumentID != "in-app-test"
    }

    init() {
        // A process exit can leave an otherwise valid-looking availability
        // marker behind. The new app process is not warm until it arms audio.
        try? store.clearQuickDictationAvailability()
        recorder.onMeter = { [weak self] level in self?.persistMeter(level) }
        recorder.onMaximumDuration = { [weak self] in self?.requestFinish() }
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

    func recoverRecentSession() async {
        guard let record = try? store.recent(limit: 1).first else {
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
            if record.state == .launchingApp {
                try record.transition(to: .recording)
            } else if record.state == .awaitingReturn {
                try record.transition(to: .recording)
            }
            record.localAudioReference = audioURL.lastPathComponent
            try store.save(record)
            activeRecord = record
            message = "Recording. Swipe back to the app where you want to type."
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
            await fail(
                &record,
                state: .serverUnavailable,
                code: "gateway_not_configured",
                message: "Configure and test the private Mac gateway in Local Flow."
            )
            return
        }

        do {
            if record.state == .finalizing || record.canRetry {
                try record.transition(to: .uploading)
            }
            try store.save(record)
            activeRecord = record
            message = "Uploading to your Mac…"
            liveActivity.update(status: "Sending to Mac", canFinish: false)

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
            message = "Transcribing on your Mac…"
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
                forKey: "gatewayHealthMessage"
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
              let baseURL = URL(string: value),
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
