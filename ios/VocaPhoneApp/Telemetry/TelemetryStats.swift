import Foundation

/// Content-free counters describing whether reporting is actually working.
///
/// ## Why this exists
///
/// The delivery path swallows every failure by design, so that a network problem
/// can never surface to someone who did not ask for this feature to work. That is
/// correct in production and actively harmful while debugging: with nothing
/// logged and nothing shown, an empty queue means either "delivered" or "never
/// recorded", and no signal on the device distinguishes them.
///
/// ## What it holds
///
/// Counts, an outcome name, and a clock time. No event names, no property
/// values, no payloads — nothing that could identify a person or reveal what
/// they dictated. In memory only; it resets with the process.
struct TelemetryStats {

    private var recordedCount = 0
    private var deliveredEvents = 0
    private var rejectedBatches = 0
    private var unavailableBatches = 0
    private var lastOutcome: TelemetryDelivery?
    private var lastAttemptAt: Date?

    mutating func recorded() {
        recordedCount += 1
    }

    mutating func attempted(_ delivery: TelemetryDelivery, batchSize: Int, at: Date) {
        lastOutcome = delivery
        lastAttemptAt = at
        switch delivery {
        case .delivered: deliveredEvents += batchSize
        case .rejected: rejectedBatches += 1
        case .unavailable: unavailableBatches += 1
        }
    }

    var summary: String {
        var line = "\(recordedCount) recorded · \(deliveredEvents) sent"
        if rejectedBatches > 0 { line += " · \(rejectedBatches) rejected" }
        if unavailableBatches > 0 {
            line += " · \(unavailableBatches) could not reach the server"
        }
        guard let lastOutcome, let lastAttemptAt else {
            return line + "\nNo send attempted yet this session."
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        line += "\nLast attempt \(formatter.string(from: lastAttemptAt)) — "
        switch lastOutcome {
        // "Sent", not "stored": the server answers 200 to a batch it silently
        // discards — an unknown app key gets the same 200 as a good one — so
        // "accepted" is the honest claim and "stored" is not one this device can
        // make. That distinction used to be spelled out here as "check the
        // dashboard to confirm it was stored", which was written for debugging
        // on a physical phone and shipped by mistake: an ordinary user has no
        // dashboard, and telling them to check one they cannot reach reads as
        // broken. The nuance stays in this comment for whoever debugs delivery
        // next; the user only needs to know it left the phone.
        case .delivered:
            line += "sent to the server"
        case .rejected:
            line += "the server refused it; the batch was dropped"
        case .unavailable:
            line += "could not reach the server; the batch is still queued"
        }
        return line
    }
}
