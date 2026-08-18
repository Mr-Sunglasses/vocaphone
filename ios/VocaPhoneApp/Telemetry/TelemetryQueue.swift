import Foundation

/// The only identifier this client produces, and it is deliberately a weak one.
///
/// Aptabase's format: epoch seconds followed by eight random digits. It lives in
/// memory, is never written to disk, and is replaced once the app has been idle
/// for ``timeout``. It exists so the events of a single sitting can be ordered
/// relative to each other; it is not an install ID and must never become one.
/// See ``TelemetryConfig`` for why there is no persistent identifier here.
struct TelemetrySession {
    /// One hour, matching Aptabase's own SDKs. Longer would let a single
    /// "session" span a whole day and quietly become the cross-day linkage that
    /// the daily salt rotation exists to prevent.
    static let timeout: TimeInterval = 60 * 60

    private var id: String
    private var lastTouched: Date
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        self.id = Self.mint(at: now())
        self.lastTouched = now()
    }

    /// The current session, rotating first if the app has been idle long enough.
    mutating func currentId() -> String {
        let timestamp = now()
        if timestamp.timeIntervalSince(lastTouched) >= Self.timeout {
            id = Self.mint(at: timestamp)
        }
        lastTouched = timestamp
        return id
    }

    /// Forces a new session. Used when reporting is switched off and on again,
    /// so a re-enable cannot be stitched to the events that preceded it.
    mutating func rotate() {
        id = Self.mint(at: now())
        lastTouched = now()
    }

    private static func mint(at date: Date) -> String {
        let seconds = Int(date.timeIntervalSince1970)
        // Zero-padded so the suffix is always eight digits: an unpadded random
        // number would make a session minted at the same second collide in
        // length with a different one, which is exactly the sort of
        // near-duplicate that looks like a bug in a query six months from now.
        let suffix = String(format: "%08d", Int.random(in: 0..<100_000_000))
        return "\(seconds)\(suffix)"
    }
}

/// Events waiting for a flush.
///
/// In memory and bounded. Because there is no persistent identity behind these
/// events (see ``TelemetryConfig``), one that never reaches the server is simply
/// gone — so a disk-backed queue would add storage, code, and privacy surface to
/// protect data that is worth none of it.
///
/// Overflow drops the **oldest**. A queue that dropped the newest would go deaf
/// exactly when something started going wrong repeatedly, which is the one
/// moment the events matter.
struct TelemetryQueue {
    private var pending: [TelemetryRecord] = []
    private let capacity: Int

    init(capacity: Int = TelemetryConfig.maxQueue) {
        self.capacity = capacity
    }

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }

    /// A copy, oldest first, for the "See what's sent" screen.
    var all: [TelemetryRecord] { pending }

    mutating func add(_ record: TelemetryRecord) {
        pending.append(record)
        if pending.count > capacity {
            pending.removeFirst(pending.count - capacity)
        }
    }

    /// Removes and returns up to ``TelemetryConfig/maxBatch`` events, oldest
    /// first. Taken rather than peeked because a failed batch is dropped, not
    /// retried indefinitely.
    mutating func takeBatch() -> [TelemetryRecord] {
        let size = Swift.min(pending.count, TelemetryConfig.maxBatch)
        guard size > 0 else { return [] }
        let batch = Array(pending.prefix(size))
        pending.removeFirst(size)
        return batch
    }

    /// Puts a failed batch back at the front, so ordering survives one retry.
    ///
    /// Overflow still drops from the front, which means part of the batch being
    /// requeued. That is the right end: those are the oldest events in the
    /// queue, and trimming the tail instead would discard whatever arrived
    /// while the send was in flight — the newest events, which is the opposite
    /// of the policy everywhere else here.
    mutating func requeue(_ batch: [TelemetryRecord]) {
        pending.insert(contentsOf: batch, at: 0)
        if pending.count > capacity {
            pending.removeFirst(pending.count - capacity)
        }
    }

    mutating func clear() {
        pending.removeAll()
    }
}
