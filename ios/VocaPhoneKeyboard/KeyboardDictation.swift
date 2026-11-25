import Foundation
import UIKit

/// A dictation the keyboard records and sends to the gateway by itself, so a
/// gateway user never leaves the app they are typing in.
///
/// It drives the same shared `SessionRecord` the app would — `recording`,
/// `finalizing`, `uploading`, `transcribing`, `readyToInsert` — so the
/// dictation bar, Finish, Cancel, Retry and insertion all work unchanged. The
/// record carries `capturedInKeyboard`, which keeps the app from claiming or
/// uploading it.
///
/// The audio goes to the gateway while the user is still speaking, through
/// the app's own `StreamingAudioBridge` and `GatewayClient`: the incremental
/// WebSocket when the model decodes as it hears, otherwise a streamed upload
/// that the gateway finishes the moment Finish closes it. The WAV written
/// beside it is the fallback, exactly as in the app: a stream that fails or
/// falls behind is abandoned and the file is sent after Finish instead.
///
/// Used only when the gateway is the route, Quick Dictation is not standing
/// by, the app has shared the gateway and its token, and vocaphone already has
/// microphone permission. Anything else, or a microphone that does not start,
/// falls back to opening vocaphone exactly as before. On-device transcription
/// never runs here: the models do not fit in a keyboard's memory.
@MainActor
final class KeyboardDictation {
    struct Gateway: Sendable {
        let baseURL: URL
        let token: String

        var client: GatewayClient { GatewayClient(baseURL: baseURL, token: token) }
    }

    private enum Phase {
        case idle
        /// The tap happened; the microphone has not delivered audio yet, and
        /// nothing is saved.
        case starting
        case recording
        /// Finish was asked for and the page has not reported `stopped` yet.
        /// The record already says `finalizing` in this window, and a refresh
        /// must not read that back as another request to finish.
        case stopping
        case sending
    }

    /// One dictation's state, dropped as a whole when it ends.
    private struct Dictation {
        let sessionID: UUID
        let gateway: Gateway
        let language: String
        let style: String
        let contextTerms: [String]
        let tappedAt: ContinuousClock.Instant
        /// One bridge per dictation: a cancel still in flight for the last one
        /// can never reach this one's stream.
        let bridge = StreamingAudioBridge()
        var file: KeyboardRecordingFile?
        /// The recording being sent when there is no file being written: a
        /// Retry sends a WAV saved earlier, and cancelling it must delete
        /// that one.
        var savedAudioURL: URL?
        var chunks: AsyncStream<Data>.Continuation?
        var droppedChunks = 0
        var finishedAt: ContinuousClock.Instant?
        var pendingLevels: [Float] = []
        var meterSequence = 0
        var lastMeterFlush = Date.distantPast
    }

    /// About 30 seconds of 16 kHz audio waiting on a slow network. Past that
    /// the stream is abandoned for the file rather than growing in a process
    /// iOS kills at a few tens of megabytes.
    private static let streamBacklogChunks = 700

    /// How long Finish waits for a stream still opening — a short dictation
    /// can end before its handshake does. Buffered samples sent on an open
    /// stream beat the complete-file fallback, which encodes and uploads
    /// everything after Finish.
    private static let streamOpenGrace: Duration = .seconds(3)

    /// One per keyboard process. iOS recreates the keyboard's view controller
    /// while the process lives on, and a dictation still sending must belong
    /// to the process, not to the controller that started it.
    static let shared = KeyboardDictation(store: .shared)

    private let store: SharedStore
    /// Kept loaded between dictations while the keyboard is on screen, so the
    /// second dictation does not wait for WebKit to start again.
    private var capture: KeyboardMicrophoneCapture?
    private var phase = Phase.idle
    private var dictation: Dictation?
    private var fallback: (() -> Void)?
    private var bridgeStarted: Task<Void, Never>?
    private var startTimeout: Task<Void, Never>?
    private var lengthCap: Task<Void, Never>?
    private var stopTimeout: Task<Void, Never>?
    private var sending: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var releaseWhenIdle = false

    /// Called after every change this object makes to the record, on a later
    /// turn of the run loop.
    var onChange: (() -> Void)?

    init(store: SharedStore) {
        self.store = store
    }

    /// What the keyboard needs to record a new dictation, or nil when it
    /// should go through vocaphone instead.
    static func gateway(quickDictationReady: Bool) -> Gateway? {
        guard KeyboardGatewayAccess.enabled,
              !LocalTranscriptionPreferences.enabled,
              !quickDictationReady,
              KeyboardMicrophoneCapture.isPermitted
        else { return nil }
        return credentials()
    }

    /// The gateway and token the app shared. Enough to resend a saved
    /// recording, which needs neither the microphone nor the setting.
    static func credentials() -> Gateway? {
        guard let baseURL = KeyboardGatewayAccess.baseURL,
              let token = KeychainStore.loadSharedToken(), !token.isEmpty
        else { return nil }
        return Gateway(baseURL: baseURL, token: token)
    }

    // MARK: Liveness across processes

    /// A file per session, touched every two seconds by the process recording
    /// or sending it. A keyboard in another app — another process — reads its
    /// age to tell a dictation still being sent from one whose keyboard iOS
    /// ended. A file rather than a lock: iOS terminates a suspended process
    /// that holds a lock in a shared container. Holds no content.
    private nonisolated static let heartbeatInterval: Duration = .seconds(2)
    /// Several missed beats: the process is gone or suspended.
    nonisolated static let heartbeatTimeout: TimeInterval = 8

    private nonisolated static func heartbeatURL(for id: UUID) -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        )?.appendingPathComponent("keyboard-dictation-\(id.uuidString).alive")
    }

    /// Whether some keyboard process is still working on `id`.
    nonisolated static func isAlive(_ id: UUID, now: Date = Date()) -> Bool {
        guard let url = heartbeatURL(for: id),
              let touched = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        else { return false }
        return now.timeIntervalSince(touched) < heartbeatTimeout
    }

    private func startHeartbeat(for id: UUID) {
        heartbeat?.cancel()
        heartbeat = Task.detached(priority: .utility) {
            guard let url = Self.heartbeatURL(for: id) else { return }
            while !Task.isCancelled {
                // Atomic, so the file is replaced and its date moves even
                // though its (empty) content never changes.
                try? Data().write(to: url, options: .atomic)
                try? await Task.sleep(for: Self.heartbeatInterval)
            }
            // Removed by the beating task itself, after its last write.
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes the heartbeat a process that died left behind.
    nonisolated static func forgetHeartbeat(_ id: UUID) {
        if let url = heartbeatURL(for: id) { try? FileManager.default.removeItem(at: url) }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    /// Deletes the saved recording of a keyboard session that ended without
    /// this process: cancelled or expired from another keyboard, or put away
    /// by a new dictation. Otherwise only the app's sweep would remove it.
    static func discardAudio(of record: SessionRecord) {
        guard record.capturedInKeyboard == true,
              let reference = record.localAudioReference,
              let url = KeyboardRecordingFile.url(for: reference)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Recording, stopping or sending: the process must stay alive for it.
    var isBusy: Bool { phase != .idle }

    func owns(_ id: UUID) -> Bool { dictation?.sessionID == id }

    /// The dictation in hand, from the tap on — before its record exists.
    var currentSessionID: UUID? { dictation?.sessionID }

    // MARK: Starting

    /// Starts the microphone for `template`, an `idle` record the caller built.
    /// The record is saved only once audio is flowing, so a microphone that
    /// does not start leaves nothing behind and `fallback` opens vocaphone.
    func start(
        _ template: SessionRecord,
        gateway: Gateway,
        contextTerms: [String],
        host: UIView,
        started: @escaping (SessionRecord) -> Void,
        fallback: @escaping () -> Void
    ) {
        end(deleteAudio: true)
        releaseWhenIdle = false
        phase = .starting
        dictation = Dictation(
            sessionID: template.sessionID,
            gateway: gateway,
            language: template.language,
            style: template.style,
            contextTerms: contextTerms,
            tappedAt: .now
        )
        self.fallback = fallback
        openTransport(for: template)
        let warm = capture?.isWarm == true
        let capture = capture ?? KeyboardMicrophoneCapture(host: host)
        capture.attach(to: host)
        self.capture = capture
        let id = template.sessionID
        startHeartbeat(for: id)
        capture.onEvent = { [weak self] event in
            guard let self, self.dictation?.sessionID == id else { return }
            switch event {
            case let .started(sampleRate):
                guard self.phase == .starting else { return }
                self.startTimeout?.cancel()
                self.beginRecording(template, sampleRate: sampleRate, warm: warm, started: started)
            case let .samples(data, peak):
                self.receive(data, peak: peak)
            case .stopped:
                self.captureStopped()
            case .failed:
                // A page that failed once is not trusted with the next one.
                self.discardCapture()
                if self.phase == .starting {
                    self.giveUp(id)
                } else {
                    self.captureLost()
                }
            }
        }
        // A web view that never answers is no better than a refusal.
        startTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.discardCapture()
            self?.giveUp(id)
        }
        capture.start()
    }

    /// Connects to the gateway at the tap, alongside the microphone starting
    /// rather than after it: on a slow link the handshake is a couple of round
    /// trips, and a short dictation used to end before it did. Audio waits in
    /// the stream until the transport is ready. A microphone that then fails
    /// to start cancels it, and the gateway's half-made session is either
    /// reused by vocaphone (same session ID) or swept up with its other
    /// abandoned sessions.
    private func openTransport(for template: SessionRecord) {
        guard var current = dictation else { return }
        let (chunks, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .bufferingOldest(Self.streamBacklogChunks)
        )
        current.chunks = continuation
        dictation = current
        let id = template.sessionID
        let client = current.gateway.client
        let language = template.language
        let style = template.style
        let bridge = current.bridge
        let uploadFinished: @Sendable () async -> Void = { [weak self] in
            await self?.uploadBodyFinished(id)
        }
        bridgeStarted = Task {
            await bridge.start(chunks: chunks) {
                // Streaming or not is decided by what the gateway says about
                // the model loaded now, every time: a model changed since the
                // last dictation is never assumed either way.
                try await client.negotiatedRecordingTransport(
                    sessionID: id, language: language, style: style,
                    sampleRate: Int(CaptureFormat.sampleRate),
                    onUploadFinished: uploadFinished
                )
            }
        }
    }

    /// The microphone did not start: nothing was saved, so vocaphone takes the
    /// dictation the way it always has.
    private func giveUp(_ id: UUID) {
        guard phase == .starting, dictation?.sessionID == id, let fallback else { return }
        DiagnosticLog.record(.keyboardCaptureFailed)
        end(deleteAudio: true)
        fallback()
    }

    private func beginRecording(
        _ template: SessionRecord,
        sampleRate: Double,
        warm: Bool,
        started: (SessionRecord) -> Void
    ) {
        guard var current = dictation else { return }
        var record = template
        do {
            let file = try KeyboardRecordingFile(sessionID: record.sessionID, inputSampleRate: sampleRate)
            current.file = file
            record.capturedInKeyboard = true
            record.processingLocation = .gateway
            record.localAudioReference = file.url.lastPathComponent
            try record.transition(to: .recording)
            _ = try store.save(record)
        } catch {
            // Nothing usable was saved; the app can still take it.
            if let url = current.file?.url { try? FileManager.default.removeItem(at: url) }
            current.file = nil
            dictation = current
            giveUp(record.sessionID)
            return
        }
        fallback = nil
        phase = .recording
        DiagnosticLog.record(
            .keyboardCaptureStarted,
            metadata: .keyboardCaptureStarted(milliseconds: Self.milliseconds(since: current.tappedAt), warm: warm)
        )

        dictation = current
        let id = record.sessionID

        let cap = RecordingLengthLimit.effectiveSeconds(
            choice: KeyboardPreferences.maximumRecordingLength,
            location: .gateway,
            gatewayReportedSeconds: KeyboardGatewayAccess.reportedMaximumDurationSeconds
        )
        lengthCap = Task { [weak self] in
            try? await Task.sleep(for: .seconds(cap))
            guard !Task.isCancelled, let self, self.owns(id) else { return }
            self.finish()
        }
        started(record)
    }

    // MARK: Recording

    private func receive(_ data: Data, peak: Float) {
        guard phase == .recording || phase == .stopping, var current = dictation,
              let file = current.file
        else { return }
        if let converted = file.append(int16: data), let chunks = current.chunks,
           case .dropped = chunks.yield(converted)
        {
            current.droppedChunks += 1
        }
        // The same shape as the app's meter: the square root of a level, a
        // handful per write, a few writes a second.
        current.pendingLevels.append(min(1, peak.squareRoot()))
        let now = Date()
        if now.timeIntervalSince(current.lastMeterFlush) >= 0.2 {
            current.lastMeterFlush = now
            current.meterSequence += current.pendingLevels.count
            try? store.saveMeter(
                MeterSample(sequence: current.meterSequence, levels: current.pendingLevels),
                for: current.sessionID
            )
            current.pendingLevels = []
        }
        dictation = current
    }

    /// Finish, from the keyboard's button, the length cap, the keyboard
    /// leaving the screen, or a `finalizing` written by another process.
    func finish() {
        guard phase == .recording, let id = dictation?.sessionID else { return }
        phase = .stopping
        dictation?.finishedAt = .now
        lengthCap?.cancel()
        mutate(id) { record in
            if record.state == .recording { try record.transition(to: .finalizing) }
        }
        capture?.stop()
        // A page that never confirms the stop must not strand the dictation
        // in "Finishing": what was written is sent anyway.
        stopTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.phase == .stopping, self.owns(id) else { return }
            self.captureStopped()
        }
    }

    /// The keyboard is leaving the screen. A recording is finished and sent;
    /// a microphone still starting is stopped before it can record anything
    /// off screen, and does not open vocaphone behind the user's back.
    func keyboardWillHide() {
        switch phase {
        case .starting:
            end(deleteAudio: true)
        case .recording:
            finish()
        case .idle, .stopping, .sending:
            break
        }
    }

    /// The page stopped: on Finish, or on its own (the input went away), which
    /// is treated as Finish.
    private func captureStopped() {
        guard phase == .recording || phase == .stopping, var current = dictation,
              let file = current.file
        else { return }
        stopTimeout?.cancel()
        lengthCap?.cancel()
        if current.finishedAt == nil { current.finishedAt = .now }
        phase = .sending
        current.chunks?.finish()
        current.chunks = nil
        // Closed before anything reads it: the header's sizes and the last
        // samples are written as it closes.
        file.close()
        dictation = current
        let id = current.sessionID
        let seconds = file.seconds
        mutate(id) { record in
            if record.state == .recording { try record.transition(to: .finalizing) }
            record.recordedSeconds = seconds
        }
        if file.peak <= CaptureFormat.silenceThreshold {
            // What a microphone another app has taken delivers.
            try? FileManager.default.removeItem(at: file.url)
            fail(id, state: .transcriptionFailedPermanent, code: "microphone_silenced",
                 message: "No sound was recorded. Check that no other app is using the microphone.",
                 recoverable: false)
            return
        }
        send(fileURL: file.url, fileComplete: !file.writeFailed, useStream: true)
        // After the send is under way: giving the route back can take a while.
        KeyboardMicrophoneCapture.releaseAudioSession()
    }

    /// WebKit's content process ended mid-recording. What was written is
    /// kept, and Retry sends it.
    private func captureLost() {
        guard phase == .recording || phase == .stopping, let id = dictation?.sessionID else { return }
        DiagnosticLog.record(.keyboardCaptureFailed)
        KeyboardMicrophoneCapture.releaseAudioSession()
        mutate(id) { record in
            if record.state == .recording { try record.transition(to: .finalizing) }
        }
        fail(id, state: .uploadFailedRecoverable, code: "keyboard_capture_lost",
             message: "The recording stopped early. Retry to send what was recorded.", recoverable: true)
    }

    // MARK: Sending

    /// Retry of a keyboard recording whose upload failed, from its saved file.
    /// False when the file is gone, so the caller can say so.
    func retry(_ record: SessionRecord, gateway: Gateway) -> Bool {
        guard phase == .idle,
              let reference = record.localAudioReference,
              let url = KeyboardRecordingFile.url(for: reference),
              FileManager.default.fileExists(atPath: url.path)
        else { return false }
        dictation = Dictation(
            sessionID: record.sessionID, gateway: gateway, language: record.language,
            style: record.style, contextTerms: [], tappedAt: .now, savedAudioURL: url, finishedAt: .now
        )
        phase = .sending
        startHeartbeat(for: record.sessionID)
        send(fileURL: url, fileComplete: true, useStream: false)
        return true
    }

    private func send(fileURL: URL, fileComplete: Bool, useStream: Bool) {
        guard let current = dictation else { return }
        let id = current.sessionID
        mutate(id) { record in
            record.error = nil
            if record.state != .uploading { try record.transition(to: .uploading) }
        }
        let bridge = current.bridge
        let bridgeStarted = bridgeStarted
        let dropped = current.droppedChunks
        let client = current.gateway.client
        let language = current.language
        let style = current.style
        sending = Task { [weak self] in
            do {
                var transcript: String?
                if useStream {
                    // The stream may still be opening; it has every sample
                    // buffered, so it is waited for, briefly, rather than
                    // skipped for the much slower file.
                    await bridgeStarted?.value
                    await bridge.waitUntilOpen(timeout: Self.streamOpenGrace)
                    transcript = await bridge.finish(droppedChunks: dropped)
                }
                let streamed = transcript != nil
                if transcript == nil {
                    guard fileComplete else { throw GatewayError.api(status: 507, code: "audio_missing") }
                    // Idempotent on the gateway: a session the stream already
                    // created, or finished, is returned as it is.
                    let created = try await client.createSession(id: id, language: language, style: style)
                    if created.state == "completed", let text = created.transcript, !text.isEmpty {
                        transcript = text
                    } else {
                        let uploaded = try await client.uploadAudio(
                            sessionID: id, fileURL: fileURL, finishOnUpload: true,
                            onUploadFinished: { [weak self] in await self?.uploadBodyFinished(id) }
                        )
                        let finished = try await client.finishUploaded(sessionID: id, uploaded: uploaded)
                        guard let text = finished.transcript, !text.isEmpty else {
                            throw GatewayError.api(status: 500, code: finished.errorCode ?? "empty_transcript")
                        }
                        transcript = text
                    }
                }
                try Task.checkCancellation()
                guard let self, let transcript else { return }
                self.delivered(transcript, streamed: streamed, fileURL: fileURL)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                self.handleSendFailure(error, fileURL: fileURL)
            }
        }
    }

    private func delivered(_ raw: String, streamed: Bool, fileURL: URL) {
        guard phase == .sending, let current = dictation else { return }
        if let finishedAt = current.finishedAt {
            DiagnosticLog.record(
                .gatewayTranscriptionTimed,
                metadata: .gatewayTranscriptionTimed(
                    milliseconds: Self.milliseconds(since: finishedAt), audioSentEarly: streamed
                )
            )
        }
        let transcript = DictatedTranscript.finished(
            raw,
            style: WritingStyle(rawValue: current.style) ?? .casual,
            language: current.language,
            styledUpstream: true,
            repairSpeech: KeyboardPreferences.repairSpeech,
            numbersAsDigits: KeyboardPreferences.numbersAsDigits,
            spokenEmoji: KeyboardPreferences.spokenEmoji,
            chineseScript: KeyboardPreferences.chineseScript,
            // Spelling in this process only: the terms are never sent.
            contextTerms: current.contextTerms
        )
        let saved = mutate(current.sessionID) { record in
            // Another keyboard may have given up on this one meanwhile; a
            // transcript that arrives late still lands.
            if record.canRetry { try record.transition(to: .uploading) }
            record.transcript = transcript
            record.error = nil
            try record.transition(to: .readyToInsert)
        }
        // Success-path deletion, as in the app — and only once the transcript
        // is safely in the record, so a failed save still leaves Retry. A
        // session cancelled meanwhile has no Retry to keep it for.
        if saved || sessionEnded(current.sessionID) { try? FileManager.default.removeItem(at: fileURL) }
        DiagnosticLog.record(.transcriptReady)
        end(deleteAudio: false)
    }

    /// The body reached the gateway; what is left is the model's work.
    private func uploadBodyFinished(_ id: UUID) {
        guard phase == .sending, owns(id) else { return }
        mutate(id) { record in
            if record.state == .uploading { try record.transition(to: .transcribing) }
        }
    }

    private func handleSendFailure(_ error: Error, fileURL: URL) {
        guard let id = dictation?.sessionID else { return }
        let status: Int?
        let code: String
        if case let GatewayError.api(apiStatus, apiCode) = error {
            status = apiStatus
            code = apiCode
        } else if let url = error as? URLError {
            status = nil
            code = "url_error_\(url.code.rawValue)"
        } else {
            status = nil
            code = "unknown"
        }
        if DictationFailure.gatewayFoundNoSpeech(code: code) {
            try? FileManager.default.removeItem(at: fileURL)
            fail(id, state: .transcriptionFailedPermanent, code: DictationFailure.noSpeechCode,
                 message: DictationFailure.noSpeechMessage, recoverable: false)
        } else if code == "language_unsupported" {
            fail(id, state: .transcriptionFailedPermanent, code: code,
                 message: "Your gateway's model does not support this language. "
                     + "Choose Automatic or another language in Settings.",
                 recoverable: false)
        } else if code == "audio_missing" {
            fail(id, state: .uploadFailedRecoverable, code: code,
                 message: "Only part of this recording could be saved — this iPhone may be out of storage. "
                     + "Retry to send the part that was saved.",
                 recoverable: true)
        } else if status == 401 || status == 403 {
            fail(id, state: .uploadFailedRecoverable, code: "token_rejected",
                 message: "The gateway rejected the pairing token. Pair again in vocaphone, then retry.",
                 recoverable: true)
        } else {
            let unreachable = error is URLError
            fail(id, state: unreachable ? .serverUnavailable : .uploadFailedRecoverable, code: code,
                 message: unreachable
                     ? "Check that your gateway is running and connected, then retry. Your recording is kept."
                     : "Check your gateway and its selected model, then retry. Your recording is kept.",
                 recoverable: true)
        }
    }

    private func fail(_ id: UUID, state: SessionState, code: String, message: String, recoverable: Bool) {
        mutate(id) { record in
            record.error = SessionFailure(code: code, message: message, recoverable: recoverable)
            try record.transition(to: Self.failureState(state, from: record.state))
        }
        // The file stays for Retry when the failure is recoverable and the
        // session has not been cancelled meanwhile.
        end(deleteAudio: !recoverable || sessionEnded(id))
    }

    /// Cancelled, expired or deleted by another writer.
    private func sessionEnded(_ id: UUID) -> Bool {
        guard let record = try? store.load(id) else { return true }
        return record.state.isTerminal
    }

    /// The failure as the record can take it from where it is: once the
    /// audio is at the gateway the record says `transcribing`, which only a
    /// transcription failure may follow.
    static func failureState(_ wanted: SessionState, from current: SessionState) -> SessionState {
        switch (current, wanted) {
        case (.transcribing, .uploadFailedRecoverable): .transcriptionFailedRecoverable
        case (.finalizing, .serverUnavailable): .uploadFailedRecoverable
        default: wanted
        }
    }

    // MARK: Ending

    /// Cancel or expiry, written by the keyboard's own button or another
    /// process: stop everything and drop the audio.
    func cancel(_ id: UUID) {
        guard owns(id) else { return }
        end(deleteAudio: true)
    }

    /// Follows a change another writer made: the app's Finish or Cancel, or an
    /// expiry.
    func observe(_ record: SessionRecord) {
        guard owns(record.sessionID) else { return }
        switch record.state {
        case .finalizing where phase == .recording:
            finish()
        case .canceled, .expired:
            cancel(record.sessionID)
        default:
            break
        }
    }

    /// Drops the capture page once nothing is recording or sending: it is the
    /// largest thing this adds to the keyboard's memory. Called when the
    /// keyboard leaves the screen and under memory pressure; a dictation still
    /// sending keeps it until it ends.
    func releaseIdleResources() {
        releaseWhenIdle = true
        if phase == .idle { discardCapture() }
    }

    private func end(deleteAudio: Bool) {
        startTimeout?.cancel()
        lengthCap?.cancel()
        stopTimeout?.cancel()
        sending?.cancel()
        sending = nil
        bridgeStarted = nil
        fallback = nil
        if phase == .recording || phase == .stopping || phase == .starting {
            capture?.stop()
            KeyboardMicrophoneCapture.releaseAudioSession()
        }
        if let current = dictation {
            current.chunks?.finish()
            if deleteAudio, let url = current.file?.url ?? current.savedAudioURL {
                try? FileManager.default.removeItem(at: url)
            }
            let bridge = current.bridge
            Task { await bridge.cancel() }
        }
        dictation = nil
        phase = .idle
        stopHeartbeat()
        if releaseWhenIdle { discardCapture() }
    }

    private func discardCapture() {
        capture?.dispose()
        capture = nil
    }

    /// Applies `change` to the newest stored copy and writes it back with a
    /// compare-and-swap, so a Cancel another process writes in between is
    /// never overwritten: the change is simply made again on top of it, or
    /// dropped once the session has ended. False when nothing was written.
    @discardableResult
    private func mutate(_ id: UUID, _ change: (inout SessionRecord) throws -> Void) -> Bool {
        for _ in 0..<3 {
            guard var record = try? store.load(id), !record.state.isTerminal else { return false }
            let expected = record.revision
            do {
                try change(&record)
            } catch {
                return false
            }
            do {
                _ = try store.save(record, expectingRevision: expected)
            } catch SharedStoreError.revisionConflict {
                continue
            } catch {
                return false
            }
            // On the next turn of the run loop, never from inside this call:
            // the controller's refresh calls back into `observe`, and a
            // synchronous round trip is how one Finish became infinite
            // recursion.
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
            return true
        }
        return false
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }
}
