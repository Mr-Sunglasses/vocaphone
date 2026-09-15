import Foundation

/// Whether `LocalModelManager.startDownload` may begin a new transfer.
/// Extracted so the concurrent-download cap can be tested without the network.
enum ModelDownloadStartDecision: Equatable, Sendable {
    case alreadyThisModel
    case alreadyQueued
    case atCapacity
    case allowed

    /// Two models at once. A third Get waits until a slot frees.
    static let maxConcurrent = 2

    static func decide(
        downloadingIDs: Set<String>,
        queuedIDs: Set<String> = [],
        requestedID: String,
        limit: Int = maxConcurrent
    ) -> Self {
        if downloadingIDs.contains(requestedID) { return .alreadyThisModel }
        if queuedIDs.contains(requestedID) { return .alreadyQueued }
        if downloadingIDs.count >= limit { return .atCapacity }
        return .allowed
    }
}
