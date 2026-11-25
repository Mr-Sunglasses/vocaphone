import Foundation
import Testing
import os

struct StreamingAudioBridgeTests {
    @Test func drainsEveryAcceptedChunkBeforeFinalizing() async throws {
        let bridge = StreamingAudioBridge()
        let transport = FakeTransport()
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        await bridge.start(chunks: chunks) { transport }
        continuation.yield(Data([1]))
        try await waitUntil { transport.state.withLock { $0.chunks.count == 1 } }
        continuation.yield(Data([2]))
        continuation.finish()
        #expect(await bridge.finish(droppedChunks: 0) == "finished")
        #expect(transport.state.withLock { $0.chunks } == [Data([1]), Data([2])])
        #expect(transport.state.withLock { $0.finalized })
    }

    @Test func droppedAudioOrSendFailureRequiresTheCompleteFileFallback() async throws {
        for failSend in [false, true] {
            let bridge = StreamingAudioBridge()
            let transport = FakeTransport(failSend: failSend)
            let (chunks, continuation) = AsyncStream<Data>.makeStream()
            await bridge.start(chunks: chunks) { transport }
            continuation.yield(Data([1]))
            try await waitUntil { transport.state.withLock { !$0.chunks.isEmpty } }
            continuation.finish()
            #expect(await bridge.finish(droppedChunks: failSend ? 0 : 1) == nil)
            #expect(transport.state.withLock { $0.cancelled })
            #expect(!transport.state.withLock { $0.finalized })
        }
    }

    @Test func cancellingWhileFinishingCancelsTheActiveTransport() async throws {
        let bridge = StreamingAudioBridge()
        let transport = FakeTransport(blockFinish: true)
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        await bridge.start(chunks: chunks) { transport }
        continuation.yield(Data([1]))
        try await waitUntil { transport.state.withLock { !$0.chunks.isEmpty } }
        continuation.finish()
        let finishing = Task { await bridge.finish(droppedChunks: 0) }
        try await waitUntil { transport.state.withLock { $0.finalized } }
        await bridge.cancel()
        #expect(await finishing.value == nil)
        #expect(transport.state.withLock { $0.cancelled })
    }

    @Test func aLateConnectionCannotReplaceTheNextRecordingsTransport() async throws {
        let bridge = StreamingAudioBridge()
        let old = FakeTransport()
        let current = FakeTransport()
        let gate = OpenGate()
        let (first, _) = AsyncStream<Data>.makeStream()
        await bridge.start(chunks: first) {
            await gate.wait()
            return old
        }
        try await waitUntil { await gate.isWaiting }
        let (second, continuation) = AsyncStream<Data>.makeStream()
        await bridge.start(chunks: second) { current }
        continuation.yield(Data([2]))
        try await waitUntil { current.state.withLock { !$0.chunks.isEmpty } }
        await gate.release()
        try await waitUntil { old.state.withLock { $0.cancelled } }
        continuation.finish()
        #expect(await bridge.finish(droppedChunks: 0) == "finished")
        #expect(old.state.withLock { $0.chunks.isEmpty })
        #expect(current.state.withLock { $0.chunks } == [Data([2])])
    }

    /// A short dictation ends before its handshake: Finish waits for the open
    /// instead of throwing the stream away for the slower file.
    @Test func finishCanWaitForAStreamStillOpening() async throws {
        let bridge = StreamingAudioBridge()
        let transport = FakeTransport()
        let gate = OpenGate()
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        await bridge.start(chunks: chunks) {
            await gate.wait()
            return transport
        }
        continuation.yield(Data([1]))
        continuation.finish()
        try await waitUntil { await gate.isWaiting }
        let waiting = Task { await bridge.waitUntilOpen(timeout: .seconds(5)) }
        await gate.release()
        await waiting.value
        #expect(await bridge.finish(droppedChunks: 0) == "finished")
        #expect(transport.state.withLock { $0.chunks } == [Data([1])])
    }

    @Test func waitingForAnOpenIsBounded() async throws {
        let bridge = StreamingAudioBridge()
        let gate = OpenGate()
        let (chunks, _) = AsyncStream<Data>.makeStream()
        await bridge.start(chunks: chunks) {
            await gate.wait()
            return FakeTransport()
        }
        try await waitUntil { await gate.isWaiting }
        let started = ContinuousClock.now
        await bridge.waitUntilOpen(timeout: .milliseconds(100))
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await bridge.finish(droppedChunks: 0) == nil)
        await gate.release()
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private actor OpenGate {
        private var waiter: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { waiter != nil }
        func wait() async { await withCheckedContinuation { waiter = $0 } }
        func release() { waiter?.resume(); waiter = nil }
    }

    private final class FakeTransport: GatewayRecordingTransport, @unchecked Sendable {
        struct State {
            var chunks: [Data] = []
            var cancelled = false
            var finalized = false
            var waiter: CheckedContinuation<String, any Error>?
        }
        let state = OSAllocatedUnfairLock(initialState: State())
        let failSend: Bool
        let blockFinish: Bool
        var readyEvent: DiagnosticEvent { .uploadStarted }

        init(failSend: Bool = false, blockFinish: Bool = false) {
            self.failSend = failSend
            self.blockFinish = blockFinish
        }

        func send(_ audio: Data) async throws {
            state.withLock { $0.chunks.append(audio) }
            if failSend { throw URLError(.networkConnectionLost) }
        }

        func finish() async throws -> String {
            if !blockFinish {
                state.withLock { $0.finalized = true }
                return "finished"
            }
            return try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock {
                    $0.finalized = true
                    if $0.cancelled { return true }
                    $0.waiter = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        }

        func cancel() {
            let waiter = state.withLock {
                $0.cancelled = true
                let waiter = $0.waiter
                $0.waiter = nil
                return waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
