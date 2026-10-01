import Foundation
import os

/// URLSession reports bytes sent before the server's response. Live bodies
/// supply their final size at EOF; file uploads supply it in the delegate call.
final class GatewayUploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private struct State {
        var sent: Int64 = 0
        var expected: Int64?
        var cancelled = false
        var notification: Task<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onUploadFinished: @Sendable () async -> Void

    init(onUploadFinished: @escaping @Sendable () async -> Void) {
        self.onUploadFinished = onUploadFinished
    }

    func bodyClosed(bytes: Int64) {
        state.withLock { $0.expected = bytes }
        notifyIfSent()
    }

    func sent(bytes: Int64, expected: Int64 = NSURLSessionTransferSizeUnknown) {
        state.withLock {
            $0.sent = bytes
            if expected > 0 { $0.expected = expected }
        }
        notifyIfSent()
    }

    private func notifyIfSent() {
        state.withLock { current in
            guard !current.cancelled, current.notification == nil,
                  let expected = current.expected, expected > 0,
                  current.sent >= expected else { return }
            current.notification = Task {
                guard !Task.isCancelled else { return }
                await onUploadFinished()
            }
        }
    }

    func waitForNotification() async {
        await state.withLock { $0.notification }?.value
    }

    func cancel() {
        state.withLock {
            $0.cancelled = true
            $0.notification?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        sent(bytes: totalBytesSent, expected: totalBytesExpectedToSend)
    }
}

/// Sends a WAV body of initially unknown length to the existing session PUT.
/// The transport buffer is bounded; a stalled link fails back to the local WAV.
final class GatewayRecordingUpload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var bodyOffered = false
        var bytesWritten: Int64 = 0
        var cancelled = false
        var data = Data()
        var result: Result<GatewaySession, any Error>?
        var waiter: CheckedContinuation<GatewaySession, any Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let input: InputStream
    private let output: OutputStream
    private let writer = DispatchQueue(label: "com.vocahq.vocaphone.recording-upload", qos: .userInitiated)
    private var session: URLSession!
    private var task: URLSessionUploadTask!
    private let progress: GatewayUploadProgress

    init(
        request: URLRequest, configuration: URLSessionConfiguration,
        onUploadFinished: @escaping @Sendable () async -> Void = {}
    ) throws {
        var read: InputStream?
        var write: OutputStream?
        Stream.getBoundStreams(withBufferSize: 65_536, inputStream: &read, outputStream: &write)
        guard let read, let write else { throw GatewayError.invalidResponse }
        input = read
        output = write
        progress = GatewayUploadProgress(onUploadFinished: onUploadFinished)
        super.init()
        // Covers the bounded recording plus setup/drain time. Individual writes
        // have a shorter deadline so Finish cannot wait on a stalled producer.
        configuration.timeoutIntervalForResource = AppConfiguration.maximumRecordingSeconds + GatewayClient.uploadTimeout + GatewayClient.finishTimeout
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.uploadTask(withStreamedRequest: request)
        writer.sync { output.open() }
        task.resume()
    }

    func sendHeader() async throws {
        try await write(Self.wavHeader)
    }

    func send(_ float32: Data) async throws {
        try await write(Self.pcm16(float32))
    }

    func finish() async throws -> GatewaySession {
        try Task.checkCancellation()
        let result = try await withTaskCancellationHandler {
            // All sends are awaited before Finish; closing on the same queue
            // makes EOF follow the last sample, without padding the recording.
            writer.async {
                self.output.close()
                self.progress.bodyClosed(bytes: self.state.withLock { $0.bytesWritten })
            }
            return try await withCheckedThrowingContinuation { continuation in
                let completed = state.withLock { current -> Result<GatewaySession, any Error>? in
                    if let result = current.result { return result }
                    current.waiter = continuation
                    return nil
                }
                if let completed { continuation.resume(with: completed) }
            }
        } onCancel: {
            self.cancel()
        }
        await progress.waitForNotification()
        try Task.checkCancellation()
        return result
    }

    func cancel() {
        progress.cancel()
        state.withLock { $0.cancelled = true }
        complete(.failure(CancellationError()))
        task.cancel()
        writer.async { self.output.close() }
        session.invalidateAndCancel()
    }

    private func write(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                writer.async {
                    do {
                        try self.writeSynchronously(data)
                        self.state.withLock { $0.bytesWritten += Int64(data.count) }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func writeSynchronously(_ data: Data) throws {
        let deadline = ContinuousClock.now + .seconds(8)
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < bytes.count {
                try state.withLock { current in
                    if current.cancelled { throw CancellationError() }
                    if case let .failure(error) = current.result { throw error }
                    if current.result != nil { throw GatewayError.invalidResponse }
                }
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                guard output.streamStatus == .open || output.streamStatus == .writing else {
                    throw output.streamError ?? URLError(.cannotWriteToFile)
                }
                if !output.hasSpaceAvailable {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                let count = output.write(address.advanced(by: offset), maxLength: bytes.count - offset)
                guard count >= 0 else { throw output.streamError ?? URLError(.cannotWriteToFile) }
                if count == 0 { Thread.sleep(forTimeInterval: 0.01) }
                offset += count
            }
        }
    }

    /// RIFF's unknown-size sentinel allows EOF to determine the actual length.
    /// FFmpeg already accepts this streaming WAV form in the batch upload API.
    static var wavHeader: Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32.max)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32.max)
        return data
    }

    static func pcm16(_ float32: Data) throws -> Data {
        guard float32.count.isMultiple(of: 4) else { throw GatewayError.invalidResponse }
        var result = Data(capacity: float32.count / 2)
        try float32.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let bits = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let sample = Float(bitPattern: UInt32(littleEndian: bits))
                guard sample.isFinite else { throw GatewayError.invalidResponse }
                let clipped = min(1, max(-1, sample))
                var value = Int16(clamping: Int(clipped * 32_768)).littleEndian
                withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
            }
        }
        return result
    }

    private func complete(_ result: Result<GatewaySession, any Error>) {
        let waiter = state.withLock { current in
            guard current.result == nil else { return nil as CheckedContinuation<GatewaySession, any Error>? }
            current.result = result
            let waiter = current.waiter
            current.waiter = nil
            return waiter
        }
        waiter?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        // A live request's expected length remains unknown until we close it.
        progress.sent(bytes: totalBytesSent)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        let offer = state.withLock { current in
            guard !current.bodyOffered, !current.cancelled else { return false }
            current.bodyOffered = true
            return true
        }
        // Live audio cannot be rewound. A replay request fails safely so the
        // coordinator can send the complete recoverable file instead.
        completionHandler(offer ? input : nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let accepted = state.withLock { current in
            guard current.data.count + data.count <= 1_048_576 else { return false }
            current.data.append(data)
            return true
        }
        if !accepted {
            complete(.failure(GatewayError.invalidResponse))
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result = Result {
            if let error { throw error }
            let data = state.withLock { $0.data }
            return try GatewayClient.decode(data, response: task.response, as: GatewaySession.self)
        }
        complete(result)
        writer.async { self.output.close() }
        session.finishTasksAndInvalidate()
    }
}
