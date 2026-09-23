import Foundation
import Testing

struct DiagnosticLatencyTests {
    private func entry(
        _ at: UInt64,
        _ event: DiagnosticEvent,
        state: SessionState? = nil,
        source: DiagnosticSource = .app
    ) -> DiagnosticEntry {
        DiagnosticEntry(
            uptimeMilliseconds: at,
            source: source,
            event: event,
            metadata: state.map { .state($0) } ?? .empty
        )
    }

    private func dictation(at start: UInt64, recording: UInt64, stop: UInt64, inserted: UInt64) -> [DiagnosticEntry] {
        [
            entry(start, .sessionStateChanged, state: .launchingApp, source: .keyboard),
            entry(start + recording, .sessionStateChanged, state: .recording),
            entry(stop, .finishRequested, source: .keyboard),
            entry(stop + 5, .finishRequested),
            entry(stop + 30, .captureStopped),
            entry(stop + inserted - 20, .transcriptReady),
            entry(stop + inserted, .insertionCompleted, source: .keyboard),
        ]
    }

    @Test func pairsEachSpanAcrossTheKeyboardAndTheApp() throws {
        let summary = Dictionary(
            uniqueKeysWithValues: DiagnosticLatency.summarize(
                dictation(at: 1_000, recording: 600, stop: 5_000, inserted: 900)
            ).map { ($0.label, $0) }
        )

        #expect(summary["Tap -> recording"]?.medianMilliseconds == 600)
        // Measured from the keyboard's Finish, not the app's echo of it.
        #expect(summary["Stop -> mic off"]?.medianMilliseconds == 30)
        #expect(summary["Stop -> transcript"]?.medianMilliseconds == 880)
        #expect(summary["Stop -> inserted"]?.medianMilliseconds == 900)
    }

    @Test func medianAndP95AreNearestRank() throws {
        let entries = (1...20).flatMap { n in
            dictation(
                at: UInt64(n) * 100_000,
                recording: UInt64(n) * 10,
                stop: UInt64(n) * 100_000 + 5_000,
                inserted: 500
            )
        }
        let tap = try #require(DiagnosticLatency.summarize(entries).first { $0.label == "Tap -> recording" })

        #expect(tap.count == 20)
        #expect(tap.medianMilliseconds == 100)
        #expect(tap.p95Milliseconds == 190)
    }

    @Test func aCanceledDictationDoesNotPairWithTheNextOne() {
        let entries = [
            entry(1_000, .finishRequested),
            entry(1_100, .sessionStateChanged, state: .canceled),
            entry(9_000, .insertionCompleted),
        ]

        #expect(DiagnosticLatency.summarize(entries).isEmpty)
    }

    @Test func exportLinesNameTheSpanAndSampleCount() {
        let entries = [
            entry(1_000, .sessionStateChanged, state: .launchingApp),
            entry(1_450, .sessionStateChanged, state: .recording),
        ]

        #expect(
            DiagnosticLatency.reportLines(entries)
                == ["Tap -> recording: 450 ms median, 450 ms p95 (n=1)"]
        )
    }
}
