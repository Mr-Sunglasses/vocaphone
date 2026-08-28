import Foundation

/// What is worth saying before a first-run download starts.
///
/// The catalog has always reasoned about the phone radio — the whole reason the
/// picker offers a small answer next to a 670 MB one — but nothing ever asked
/// the system whether the radio was actually in use, and nothing ever asked
/// whether the download would fit. Both answers are cheap, and both change what
/// the recommendation card should say.
///
/// Mirrors `DownloadReadiness.kt`; the wording differs where the platform does.
enum DownloadWarning: Equatable, Sendable {
    /// Not enough room. Reported before the transfer rather than after it, so a
    /// full iPhone does not spend several minutes failing.
    case notEnoughStorage(freeBytes: Int64, requiredBytes: Int64)
    /// A metered connection, where the size of the download is the user's bill.
    case meteredConnection(sizeBytes: Int64)

    /// Whether this is the hard stop rather than the judgement call. The copy
    /// around a warning changes with the answer, and an optional warning reads
    /// better here than a second pattern match at each call site.
    var isStorage: Bool {
        if case .notEnoughStorage = self { return true }
        return false
    }
}

extension Optional where Wrapped == DownloadWarning {
    var isStorage: Bool { self?.isStorage ?? false }
}

enum DownloadReadiness {
    /// Below this a download on cellular is not worth a warning. Set just under
    /// the smallest non-trivial catalog entry so the compact models — the ones
    /// the warning would point someone at — never trigger it themselves.
    static let meteredWarningThresholdBytes: Int64 = 100_000_000

    /// The headroom a download needs beyond the model itself.
    ///
    /// A model is staged and only moved into place once every digest matches,
    /// so the peak on disk is the download plus whatever the move holds. A
    /// quarter of the model, floored at 128 MB, covers that without refusing a
    /// download that would have fit.
    static func storageHeadroomBytes(_ sizeBytes: Int64) -> Int64 {
        max(128_000_000, sizeBytes / 4)
    }

    static func requiredStorageBytes(_ sizeBytes: Int64) -> Int64 {
        sizeBytes + storageHeadroomBytes(sizeBytes)
    }

    /// The one thing worth interrupting for, or nil.
    ///
    /// Storage outranks the radio: a download that cannot finish is a hard
    /// stop, while a metered one is the user's call. Only ever one warning,
    /// because two stacked cautions on a setup card are read as neither.
    static func warning(
        sizeBytes: Int64,
        freeBytes: Int64,
        metered: Bool
    ) -> DownloadWarning? {
        let required = requiredStorageBytes(sizeBytes)
        // A zero reading means the query failed, not that the disk is full.
        if freeBytes > 0, freeBytes < required {
            return .notEnoughStorage(freeBytes: freeBytes, requiredBytes: required)
        }
        if metered, sizeBytes >= meteredWarningThresholdBytes {
            return .meteredConnection(sizeBytes: sizeBytes)
        }
        return nil
    }

    static func byteLabel(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1_000 {
            return String(format: "%.1f GB", megabytes / 1_000)
        }
        return "\(Int(megabytes.rounded())) MB"
    }

    /// "412 MB of 670 MB", the line a bare percentage does not give.
    static func sizeProgress(downloadedBytes: Int64, totalBytes: Int64) -> String? {
        guard totalBytes > 0 else { return nil }
        let done = min(max(0, downloadedBytes), totalBytes)
        return "\(byteLabel(done)) of \(byteLabel(totalBytes))"
    }

    /// How much longer the transfer has, in plain words, or nil while the
    /// estimate would still be noise.
    ///
    /// A rate measured over the first second of a transfer is mostly connection
    /// setup, and an estimate that swings from "12 minutes" to "40 seconds" is
    /// worse than no estimate at all. So nothing is claimed until the transfer
    /// has both run for a moment and actually moved.
    static func timeRemaining(
        downloadedBytes: Int64,
        totalBytes: Int64,
        elapsed: TimeInterval
    ) -> String? {
        guard totalBytes > 0, downloadedBytes > 0 else { return nil }
        guard elapsed >= minimumEstimateElapsed else { return nil }
        guard downloadedBytes < totalBytes else { return nil }
        let bytesPerSecond = Double(downloadedBytes) / elapsed
        guard bytesPerSecond > 0 else { return nil }
        let seconds = Int((Double(totalBytes - downloadedBytes) / bytesPerSecond).rounded())
        switch seconds {
        case ..<10: return "a few seconds left"
        case ..<45: return "about \(((seconds + 5) / 10) * 10) seconds left"
        case ..<90: return "about a minute left"
        // Past an hour the figure is a guess dressed as a number, and saying
        // nothing is more honest than saying "about 74 minutes".
        case ..<3600: return "about \((seconds + 30) / 60) minutes left"
        default: return nil
        }
    }

    private static let minimumEstimateElapsed: TimeInterval = 2.5

    /// Free space on the volume `url` lives on, or 0 when it cannot be read.
    ///
    /// `forImportantUsage` is the figure that accounts for purgeable caches iOS
    /// would evict to make room, which is what a model download can actually
    /// claim — the raw free-bytes value understates it badly on a full phone.
    static func availableStorageBytes(at url: URL) -> Int64 {
        // The first-run `LocalModels` folder does not exist yet. Asking its URL
        // for volume capacity fails and reads as zero, which used to skip the
        // very storage check this helper exists for. Capacity belongs to the
        // volume, so walk to the nearest existing parent instead.
        let fileManager = FileManager.default
        var volumeURL = url
        while !fileManager.fileExists(atPath: volumeURL.path) {
            let parent = volumeURL.deletingLastPathComponent()
            guard parent.path != volumeURL.path else { return 0 }
            volumeURL = parent
        }
        let values = try? volumeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
