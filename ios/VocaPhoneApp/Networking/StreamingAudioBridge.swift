import Foundation

protocol GatewayRecordingTransport: Sendable {
    var readyEvent: DiagnosticEvent { get }
    func send(_ audio: Data) async throws
    func finish() async throws -> String
    func cancel()
}

extension GatewayAudioStream: GatewayRecordingTransport {
    var readyEvent: DiagnosticEvent { .streamReady }
}

private struct RecordingUploadTransport: GatewayRecordingTransport {
    let upload: GatewayRecordingUpload
    let client: GatewayClient
    let sessionID: UUID
    var readyEvent: DiagnosticEvent { .uploadStarted }

    func send(_ audio: Data) async throws { try await upload.send(audio) }
    func cancel() { upload.cancel() }

    func finish() async throws -> String {
        let uploaded = try await upload.finish()
        try Task.checkCancellation()
        let result = try await client.finishUploaded(sessionID: sessionID, uploaded: uploaded)
        guard let transcript = result.transcript, !transcript.isEmpty else {
            throw GatewayError.api(status: 500, code: result.errorCode ?? "empty_transcript")
        }
        return transcript
    }
}

extension GatewayClient {
    func recordingTransport(
        sessionID: UUID, language: String, style: String, sampleRate: Int,
        attemptTranscriptionStream: Bool,
        onUploadFinished: @escaping @Sendable () async -> Void = {}
    ) async throws -> any GatewayRecordingTransport {
        if attemptTranscriptionStream {
            do {
                return try await startAudioStream(
                    sessionID: sessionID, language: language, style: style, sampleRate: sampleRate
                )
            } catch {
                try Task.checkCancellation()
            }
        }
        let upload = try await startRecordingUpload(
            sessionID: sessionID, language: language, style: style, onUploadFinished: onUploadFinished
        )
        return RecordingUploadTransport(upload: upload, client: self, sessionID: sessionID)
    }
}

/// One bounded, ordered consumer for either incremental recognition or HTTP
/// upload during recording. Any loss abandons this path and keeps file fallback.
actor StreamingAudioBridge {
    private var stream: (any GatewayRecordingTransport)?
    private var pump: Task<Void, Never>?
    private var generation = UUID()
    private var failed = false
    private var ready = false
    private var fallbackRecorded = false

    func start(
        chunks: AsyncStream<Data>,
        open: @escaping @Sendable () async throws -> any GatewayRecordingTransport
    ) {
        cancel()
        let token = generation
        DiagnosticLog.record(.streamHandshakeStarted)
        pump = Task { [weak self] in
            do {
                let opened = try await open()
                guard !Task.isCancelled,
                      await self?.attach(opened, token: token) == true else {
                    opened.cancel()
                    return
                }
                DiagnosticLog.record(opened.readyEvent)
                for await chunk in chunks {
                    guard !Task.isCancelled else { break }
                    guard await self?.deliver(chunk, token: token) == true else { break }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await self?.openingFailed(token: token)
            }
        }
    }

    func finish(droppedChunks: Int) async -> String? {
        guard droppedChunks == 0, ready else {
            cancelTransport()
            recordFallbackIfNeeded()
            return nil
        }
        let token = generation
        // Capture has closed the chunk source. Drain every accepted sample
        // before EOF/finish; a later recording cannot inherit this transport.
        await pump?.value
        guard token == generation else { return nil }
        pump = nil
        guard !failed, let stream else {
            cancelTransport()
            recordFallbackIfNeeded()
            return nil
        }
        do {
            let transcript = try await withTaskCancellationHandler {
                try await stream.finish()
            } onCancel: {
                stream.cancel()
            }
            guard token == generation, !Task.isCancelled else { return nil }
            self.stream = nil
            ready = false
            return transcript
        } catch {
            guard token == generation else { return nil }
            cancelTransport()
            recordFallbackIfNeeded()
            return nil
        }
    }

    func cancel() {
        cancelTransport()
        fallbackRecorded = false
    }

    private func cancelTransport() {
        generation = UUID()
        pump?.cancel()
        pump = nil
        stream?.cancel()
        stream = nil
        failed = false
        ready = false
    }

    private func attach(_ opened: any GatewayRecordingTransport, token: UUID) -> Bool {
        guard token == generation else { return false }
        stream = opened
        ready = true
        return true
    }

    private func openingFailed(token: UUID) {
        guard token == generation else { return }
        failed = true
        recordFallbackIfNeeded()
    }

    private func recordFallbackIfNeeded() {
        guard !fallbackRecorded else { return }
        fallbackRecorded = true
        DiagnosticLog.record(.batchFallback)
    }

    private func deliver(_ chunk: Data, token: UUID) async -> Bool {
        guard token == generation, !failed, let stream else { return false }
        do {
            try await stream.send(chunk)
            return token == generation
        } catch {
            guard token == generation else { return false }
            failed = true
            stream.cancel()
            self.stream = nil
            return false
        }
    }
}
