import Foundation
import Testing

/// Every way the stage can fail must hand the transcript back unchanged.
/// Mirrors GrammarCorrectorTest.kt.
struct GrammarCorrectorTests {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DiagnosticEvent] = []
        private(set) var loads = 0
        private(set) var closes = 0
        func record(_ event: DiagnosticEvent) { lock.withLock { events.append(event) } }
        func loaded() { lock.withLock { loads += 1 } }
        func closed() { lock.withLock { closes += 1 } }
        var all: [DiagnosticEvent] { lock.withLock { events } }
    }

    private static let directory = FileManager.default.temporaryDirectory

    private static let keeping = GrammarFixtures.tagger { _, rows in rows.map { _ in GrammarFixtures.row("KEEP") } }

    /// Waits for the background load, which is all `warm()` does.
    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

    private func awaitLoaded(_ corrector: GrammarCorrector) async {
        for _ in 0..<250 where !corrector.isLoaded { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func withoutAModelTheTextIsUnchangedAndNothingLoads() {
        let log = Log()
        let corrector = GrammarCorrector(directory: { nil }, isReady: { false }, log: log.record) { _ in
            log.loaded()
            throw CancellationError()
        }
        #expect(corrector.correct("He don't know.", keeping: []) == "He don't know.")
        #expect(log.loads == 0)
    }

    @Test func theFirstTranscriptBeforeTheLoadFinishesIsLeftAlone() async {
        let log = Log()
        let corrector = GrammarCorrector(directory: { Self.directory }, isReady: { true }, log: log.record) { _ in
            Thread.sleep(forTimeInterval: 0.05)
            log.loaded()
            return .init(tagger: Self.keeping, close: {})
        }
        #expect(corrector.correct("He don't know.", keeping: []) == "He don't know.")
        await settle()
        #expect(log.loads == 1)
        #expect(log.all.isEmpty)
    }

    @Test func aFailedLoadIsLoggedOnceAndNotRetriedPerDictation() async {
        let log = Log()
        let corrector = GrammarCorrector(directory: { Self.directory }, isReady: { true }, log: log.record) { _ in
            log.loaded()
            throw CancellationError()
        }
        for _ in 0..<5 {
            corrector.warm()
            await settle()
            #expect(corrector.correct("He don't know.", keeping: []) == "He don't know.")
        }
        #expect(log.loads == 1)
        #expect(log.all == [.grammarLoadFailed])
    }

    @Test func aRuntimeErrorReturnsTheInputAndIsLogged() async {
        struct Boom: Error {}
        let log = Log()
        let throwing = GrammarFixtures.tagger { _, _ in throw Boom() }
        let corrector = GrammarCorrector(directory: { Self.directory }, isReady: { true }, log: log.record) { _ in
            .init(tagger: throwing, close: {})
        }
        corrector.warm()
        await awaitLoaded(corrector)
        #expect(corrector.correct("He don't know.", keeping: []) == "He don't know.")
        #expect(log.all == [.grammarFailed])
    }

    @Test func releaseDropsTheSessionAndWarmLoadsItAgain() async {
        let log = Log()
        let corrector = GrammarCorrector(directory: { Self.directory }, isReady: { true }, log: log.record) { _ in
            log.loaded()
            return .init(tagger: Self.keeping, close: log.closed)
        }
        corrector.warm()
        await awaitLoaded(corrector)
        corrector.release()
        #expect(log.closes == 1)
        corrector.warm()
        await awaitLoaded(corrector)
        #expect(log.loads == 2)
    }

    /// Greptile on #416: a release during a warm-up must not leave the session loaded.
    @Test func aReleaseDuringTheLoadClosesWhatTheLoadReturns() {
        let log = Log()
        let loading = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let corrector = GrammarCorrector(directory: { Self.directory }, isReady: { true }, log: log.record) { _ in
            loading.signal()
            _ = finish.wait(timeout: .now() + 5)
            return .init(tagger: Self.keeping, close: log.closed)
        }
        corrector.warm()
        _ = loading.wait(timeout: .now() + 5)
        corrector.release()
        finish.signal()
        for _ in 0..<250 where log.closes == 0 { Thread.sleep(forTimeInterval: 0.02) }
        #expect(log.closes == 1, "the stale session was closed")
        #expect(corrector.correct("He don't know.", keeping: []) == "He don't know.")
    }
}
