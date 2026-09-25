import Foundation
import Testing

struct DiagnosticLatencyTests {
    private func entry(
        _ at: UInt64,
        _ event: DiagnosticEvent,
        state: SessionState? = nil,
        source: DiagnosticSource = .app,
        timestamp: Date? = nil
    ) -> DiagnosticEntry {
        DiagnosticEntry(
            timestamp: timestamp ?? Date(),
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

    @Test func pairsByUptimeWhenTheAppWritesBeforeTheKeyboard() {
        // The app's queue flushed first; the keyboard's earlier tap landed after.
        let entries = [
            entry(1_600, .sessionStateChanged, state: .recording),
            entry(1_000, .sessionStateChanged, state: .launchingApp, source: .keyboard),
        ]

        #expect(
            DiagnosticLatency.reportLines(entries)
                == ["Tap -> recording: 600 ms median, 600 ms p95 (n=1)"]
        )
    }

    @Test func neverSortsAcrossAReboot() {
        let reboot = Date(timeIntervalSince1970: 2_000_000)
        let entries = [
            entry(900_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: reboot.addingTimeInterval(-120)),
            // Rebooted: uptime starts over and wall time moved forward.
            entry(2_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: reboot),
            entry(2_400, .sessionStateChanged, state: .recording, timestamp: reboot.addingTimeInterval(0.4)),
        ]

        #expect(
            DiagnosticLatency.reportLines(entries)
                == ["Tap -> recording: 400 ms median, 400 ms p95 (n=1)"]
        )
    }

    @Test func neverSortsAcrossARebootWhenClockMovesBackward() {
        let firstBoot = Date(timeIntervalSince1970: 2_000_000)
        let entries = [
            entry(100_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: firstBoot),
            entry(100_400, .sessionStateChanged, state: .recording, timestamp: firstBoot.addingTimeInterval(0.4)),
            // Rebooted with wall clock set backward: low uptime is below this boot's bootMinUptime.
            entry(2_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: firstBoot.addingTimeInterval(-3_600)),
            entry(2_400, .sessionStateChanged, state: .recording, timestamp: firstBoot.addingTimeInterval(-3_600 + 0.4)),
        ]
        #expect(
            DiagnosticLatency.reportLines(entries)
                == ["Tap -> recording: 400 ms median, 400 ms p95 (n=2)"]
        )
    }

    @Test func delayedSameBootWriteDoesNotStartANewBoot() {
        let recordingAt = Date(timeIntervalSince1970: 2_000_000)
        let entries = [
            // Establishes this boot's bootMinUptime (20_000).
            entry(20_000, .captureStopped, timestamp: recordingAt.addingTimeInterval(-80)),
            entry(100_000, .sessionStateChanged, state: .recording, timestamp: recordingAt),
            // Delayed same-boot flush: uptime drop > rebootGap, but 30_000 is still
            // at/after bootMinUptime 20_000 and wall is older than latestTimestamp.
            entry(30_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: recordingAt.addingTimeInterval(-70)),
        ]

        #expect(
            DiagnosticLatency.reportLines(entries)
                == ["Tap -> recording: 70000 ms median, 70000 ms p95 (n=1)"]
        )
    }

    @Test func delayedSameBootWriteAfterClockSetbackDoesNotStartANewBoot() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let entries = [
            // Establishes this boot's bootMinUptime (20_000) and latestTimestamp (T0).
            entry(20_000, .captureStopped, timestamp: t0),
            // Mid-boot clock set back; high uptime already processed. latestTimestamp
            // stays at T0 because the set-back wall is earlier.
            entry(100_000, .sessionStateChanged, state: .recording, timestamp: t0.addingTimeInterval(-3_600)),
            // Delayed same-boot flush: uptime drop > rebootGap, 30_000 is still
            // at/after bootMinUptime 20_000. Wall T0-10 is later than the
            // setback entry's T0-3600 but still <= latestTimestamp T0.
            entry(30_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: t0.addingTimeInterval(-10)),
        ]

        #expect(
            DiagnosticLatency.reportLines(entries)
                == ["Tap -> recording: 70000 ms median, 70000 ms p95 (n=1)"]
        )
    }

    @Test func wallForwardRebootAfterSetbackStartsNewBoot() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let entries = [
            // Establishes this boot's bootMinUptime (20_000) and latestTimestamp (T0).
            entry(20_000, .captureStopped, timestamp: t0),
            // Mid-boot clock set back; latestTimestamp stays at T0.
            entry(100_000, .sessionStateChanged, state: .recording, timestamp: t0.addingTimeInterval(-3_600)),
            // Delayed same-boot flush: 30_000 >= bootMinUptime and wall T0-10
            // is still <= latestTimestamp T0, so this stays in the first boot.
            entry(30_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: t0.addingTimeInterval(-10)),
            // Wall-forward reboot: 25_000 is still >= bootMinUptime, but wall
            // moved past latestTimestamp, so this starts a new boot.
            entry(25_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: t0.addingTimeInterval(120)),
            entry(25_400, .sessionStateChanged, state: .recording, timestamp: t0.addingTimeInterval(120.4)),
        ]

        #expect(
            DiagnosticLatency.reportLines(entries)
                == ["Tap -> recording: 400 ms median, 70000 ms p95 (n=2)"]
        )
    }

    @Test func neverMergesRebootWhenClockSetBackIntoPriorBootWallRange() {
        let firstBoot = Date(timeIntervalSince1970: 2_000_000)
        let entries = [
            entry(100_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: firstBoot),
            entry(100_400, .sessionStateChanged, state: .recording, timestamp: firstBoot.addingTimeInterval(0.4)),
            // Reboot with clock set back into the prior boot's wall range
            // (firstBoot+0.1s): wall time is still >= bootMinTimestamp and
            // < latestTimestamp under the old gate, but uptime 2000 is below
            // bootMinUptime 100000 so this is a new boot.
            entry(2_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: firstBoot.addingTimeInterval(0.1)),
            entry(2_400, .sessionStateChanged, state: .recording, timestamp: firstBoot.addingTimeInterval(0.1 + 0.4)),
        ]
        #expect(
            DiagnosticLatency.reportLines(entries)
                == ["Tap -> recording: 400 ms median, 400 ms p95 (n=2)"]
        )
    }

    @Test func neverMergesRebootWhenFirstUptimeIsAbovePriorBootMin() {
        let firstBoot = Date(timeIntervalSince1970: 2_000_000)
        let reboot = firstBoot.addingTimeInterval(120)
        let entries = [
            // File order: 5_000 then 100_000 establishes bootMinUptime = 5_000.
            entry(5_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: firstBoot),
            entry(100_000, .sessionStateChanged, state: .recording, timestamp: firstBoot.addingTimeInterval(95)),
            // Reboot: first post-reboot uptime 30_000 is still >= bootMinUptime 5_000,
            // but wall moved forward vs this boot's latestTimestamp.
            entry(30_000, .sessionStateChanged, state: .launchingApp, source: .keyboard, timestamp: reboot),
            entry(30_400, .sessionStateChanged, state: .recording, timestamp: reboot.addingTimeInterval(0.4)),
        ]
        #expect(
            DiagnosticLatency.reportLines(entries)
                == ["Tap -> recording: 400 ms median, 95000 ms p95 (n=2)"]
        )
    }
}
