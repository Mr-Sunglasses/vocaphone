import Foundation

/// Median and p95 of the dictation spans that ``DiagnosticLog`` already stamps.
///
/// Entries carry `uptimeMilliseconds`, which is monotonic across the keyboard
/// and the app for one boot, so a span may start in one process and end in the
/// other. This pairs each span's start with the first matching end inside the
/// same dictation and reports how long it took. See docs/latency.md for the
/// budgets.
///
/// Built only from event names, session states and integers, so the summary
/// is as content-free as the log it reads.
enum DiagnosticLatency {
    struct Span: Equatable, Sendable {
        let label: String
        let from: Marker
        let to: Marker
    }

    enum Marker: Equatable, Hashable, Sendable {
        case event(DiagnosticEvent)
        case state(SessionState)
    }

    struct Summary: Equatable, Sendable {
        let label: String
        let count: Int
        let medianMilliseconds: UInt64
        let p95Milliseconds: UInt64
    }

    /// Tap → recording includes the hop into the containing app, because the
    /// keyboard cannot record and the user waits through it either way.
    static let spans = [
        Span(label: "Tap -> recording", from: .state(.launchingApp), to: .state(.recording)),
        Span(label: "Stop -> mic off", from: .event(.finishRequested), to: .event(.captureStopped)),
        Span(label: "Stop -> transcript", from: .event(.finishRequested), to: .event(.transcriptReady)),
        Span(label: "Stop -> inserted", from: .event(.finishRequested), to: .event(.insertionCompleted)),
    ]

    /// States that end a dictation, so a span never pairs across two of them.
    private static let boundaries: Set<Marker> = [
        .state(.launchingApp),
        .state(.canceled),
        .state(.expired),
        .state(.permissionDenied),
        .state(.serverUnavailable),
        .state(.uploadFailedRecoverable),
        .state(.transcriptionFailedRecoverable),
        .state(.transcriptionFailedPermanent),
    ]

    static func summarize(_ entries: [DiagnosticEntry], spans: [Span] = spans) -> [Summary] {
        var samples = Array(repeating: [UInt64](), count: spans.count)
        var open = [Int: UInt64]()
        for entry in chronological(entries) {
            guard let at = entry.uptimeMilliseconds else { continue }
            let marker: Marker = if entry.event == .sessionStateChanged, let state = entry.metadata.state {
                .state(state)
            } else {
                .event(entry.event)
            }
            for (index, span) in spans.enumerated() where span.to == marker {
                if let startedAt = open.removeValue(forKey: index), at >= startedAt {
                    samples[index].append(at - startedAt)
                }
            }
            if boundaries.contains(marker) { open.removeAll() }
            // The keyboard and the app both log Finish; the first is the tap.
            for (index, span) in spans.enumerated() where span.from == marker && open[index] == nil {
                open[index] = at
            }
        }
        return zip(spans, samples).compactMap { span, values in
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return Summary(
                label: span.label,
                count: sorted.count,
                medianMilliseconds: percentile(sorted, 50),
                p95Milliseconds: percentile(sorted, 95)
            )
        }
    }

    /// A drop this large in uptime looks like a reboot. A delayed same-boot
    /// flush is distinguished by an earlier wall-clock timestamp.
    static let rebootGap: UInt64 = 60_000

    /// The log in the order things happened rather than the order they were
    /// written.
    ///
    /// The keyboard and the app each append through their own queue, so the
    /// app's `recording` can land in the file before the keyboard's earlier
    /// `launchingApp`. Uptime restarts at boot, so entries are sorted within
    /// each boot, never across one. A write delayed past `rebootGap` stays in
    /// the current boot when its wall-clock `timestamp` is earlier than the
    /// latest already seen there.
    static func chronological(_ entries: [DiagnosticEntry]) -> [DiagnosticEntry] {
        var boots: [[(offset: Int, at: UInt64, entry: DiagnosticEntry)]] = [[]]
        var latest: UInt64 = 0
        var latestTimestamp: Date?
        for (offset, entry) in entries.enumerated() {
            guard let at = entry.uptimeMilliseconds else { continue }
            if at + rebootGap < latest {
                // Earlier wall time is a delayed flush of this boot.
                let delayedFlush = latestTimestamp.map { entry.timestamp < $0 } ?? false
                if !delayedFlush {
                    boots.append([])
                    latest = 0
                    latestTimestamp = nil
                }
            }
            boots[boots.count - 1].append((offset, at, entry))
            latest = max(latest, at)
            if entry.timestamp > (latestTimestamp ?? .distantPast) {
                latestTimestamp = entry.timestamp
            }
        }
        return boots.flatMap { boot in
            boot.sorted { ($0.at, $0.offset) < ($1.at, $1.offset) }.map(\.entry)
        }
    }

    static func reportLines(_ entries: [DiagnosticEntry]) -> [String] {
        summarize(entries).map {
            "\($0.label): \($0.medianMilliseconds) ms median, \($0.p95Milliseconds) ms p95 (n=\($0.count))"
        }
    }

    /// Nearest-rank, so every reported value is one that was actually measured.
    static func percentile(_ sorted: [UInt64], _ percent: Int) -> UInt64 {
        let rank = Int((Double(percent) / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}
