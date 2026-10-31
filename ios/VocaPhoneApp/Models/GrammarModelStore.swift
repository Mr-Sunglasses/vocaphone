import Foundation
import Observation

/// Storage, download and verification for the "Fix grammar (English)" model.
///
/// Separate from `LocalModelManager` on purpose. That manager's download
/// slots, background session, picker state and sweeps all belong to speech
/// models; a 28 MB grammar download must neither queue behind a speech model
/// nor show up among them. What it shares is the part that has to be right
/// everywhere: `LocalModelIntegrity`'s per-file SHA-256 check and the
/// `.vocaphone-verified` marker with its pin fingerprint. Files land in a
/// staging folder and move into `Application Support/GrammarModels/<id>` only
/// once every one of them matches.
///
/// A dropped connection is retried with URLSession's resume data, as the
/// speech downloads do in the foreground. The model is small enough that a
/// download interrupted by the app being killed starts again.
@MainActor
@Observable
final class GrammarModelStore {
    nonisolated static let modelID = "mindtype-tagger-v2.0"

    /// Grammar models an earlier build downloaded. `removeRetired()` deletes
    /// their folders, and the app downloads the current model in their place
    /// for anyone whose grammar setting is on. Mirrors
    /// `GrammarModelCatalog.retiredIds` on Android.
    nonisolated static let retiredModelIDs = ["mindtype-tagger-v1.5"]

    enum Phase: Equatable {
        case absent
        case downloading(fraction: Double)
        case ready
        case failed(ModelDownloadFailureReason)
    }

    /// Fetches one file to a temporary location the caller then owns,
    /// reporting bytes written so far.
    typealias Fetch = @Sendable (
        _ url: URL, _ progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL

    private(set) var phase: Phase = .absent

    nonisolated let pins: LocalModelIntegrity.PinnedModelManifest?
    private nonisolated let root: URL?
    private let fetch: Fetch
    private var downloadTask: Task<Void, Error>?
    /// Bumped by `delete()`. Work that started under an older value — a
    /// download's last hash, a refresh's digest pass — must not install files
    /// or publish `.ready` afterwards.
    private var generation = 0

    nonisolated var sizeBytes: Int64 { pins?.files.reduce(0) { $0 + $1.size } ?? 0 }

    /// Where the verified files live. Only meaningful while `isReady`.
    nonisolated var directory: URL? { root?.appendingPathComponent(Self.modelID, isDirectory: true) }

    /// The folder inside `directory` holding the model's own files, in the
    /// repository's layout (`onnx/`). This is what a loader opens.
    nonisolated var modelDirectory: URL? {
        guard let directory else { return nil }
        guard let first = pins?.files.first?.path, let slash = first.lastIndex(of: "/") else { return directory }
        return directory.appendingPathComponent(String(first[..<slash]), isDirectory: true)
    }

    /// What app launch does: sweeps retired models, re-reads the folder, and
    /// downloads the current model when `wanted` says a grammar setting is on
    /// over missing files. Returns whether it downloaded one.
    ///
    /// The settings can only be turned on once the files are verified, so on
    /// over missing files means an update moved the pin or an earlier attempt
    /// at this download failed. Whoever turned the setting on agreed to the
    /// download already, so it is retried on every launch until it succeeds,
    /// not only on the launch that removed the old folder. `wanted` is asked
    /// only when the files are missing, and nobody who never turned grammar on
    /// gets a download. Mirrors `GrammarModelStore.restore` on Android.
    func restore(
        retired: [String] = GrammarModelStore.retiredModelIDs,
        wanted: () -> Bool
    ) async -> Bool {
        removeRetired(retired)
        await refresh()
        guard !isReady, wanted() else { return false }
        return (try? await download()) != nil
    }

    /// Deletes the folders of grammar models this build no longer pins, and
    /// says whether there was one.
    @discardableResult
    func removeRetired(_ retired: [String] = GrammarModelStore.retiredModelIDs) -> Bool {
        guard let root else { return false }
        var found = false
        for id in retired where id != Self.modelID {
            let folder = root.appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                found = true
                try? FileManager.default.removeItem(at: folder)
            }
            if let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
                for name in names where name.hasPrefix(".download-\(id)-") {
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
                }
            }
        }
        return found
    }

    init(
        pins: LocalModelIntegrity.PinnedModelManifest? = try? LocalModelIntegrity.grammarModel(
            for: GrammarModelStore.modelID
        ),
        root: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("GrammarModels", isDirectory: true),
        fetch: @escaping Fetch = GrammarModelStore.urlSessionFetch
    ) {
        self.pins = pins
        self.root = root
        self.fetch = fetch
        removeAbandonedStaging()
        if isReady { phase = .ready }
    }

    /// Staging folders left by an attempt the system killed mid-download. Each
    /// attempt names its own, so nothing else would ever reuse or remove them.
    private func removeAbandonedStaging() {
        guard downloadTask == nil, let root,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return }
        for name in names where name.hasPrefix(".download-\(Self.modelID)-") {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// Stat-only: safe on any path that runs per dictation, from any thread.
    nonisolated var isReady: Bool {
        guard let pins, let directory else { return false }
        return (try? LocalModelIntegrity.verifySizes(in: directory, files: pins.files)) != nil
    }

    /// Re-reads the folder. Files present at the right sizes but without a
    /// marker for these pins are hashed once here, off the main actor.
    func refresh() async {
        guard let pins, let directory else { return }
        removeAbandonedStaging()
        let started = generation
        if isReady {
            phase = .ready
            return
        }
        let files = pins.files
        let verified = await Task.detached(priority: .utility) {
            (try? LocalModelIntegrity.verifyDigests(
                in: directory, files: files, modelIdentifier: GrammarModelStore.modelID
            )) != nil
        }.value
        guard started == generation else { return }
        // A download may have finished while the digests were being checked:
        // its files are the ones on disk now, and its `.ready` stands.
        if verified || isReady {
            phase = .ready
        } else if phase == .ready, downloadTask == nil {
            phase = .absent
        }
    }

    /// Fetches and verifies every pinned file. Returns only when the model is
    /// ready; every failure throws after recording why in `phase`.
    func download() async throws {
        if let downloadTask { return try await downloadTask.value }
        let task = Task { try await performDownload() }
        downloadTask = task
        defer { downloadTask = nil }
        try await task.value
    }

    /// Stops a download in flight and discards what it fetched.
    func cancel() {
        downloadTask?.cancel()
    }

    /// Removes the model. Returns whether nothing was left behind.
    @discardableResult
    func delete() -> Bool {
        generation += 1
        cancel()
        guard let directory else { return false }
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        let removed = !FileManager.default.fileExists(atPath: directory.path)
        phase = isReady ? .ready : .absent
        return removed
    }

    private func performDownload() async throws {
        guard let pins, let root, let directory else {
            phase = .failed(.damaged)
            throw LocalModelManagerError.integrityManifestMissing(Self.modelID)
        }
        if isReady {
            phase = .ready
            return
        }
        let started = generation
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let free = DownloadReadiness.availableStorageBytes(at: root)
        let needed = DownloadReadiness.requiredStorageBytes(sizeBytes)
        if free > 0, free < needed {
            let error = LocalModelManagerError.insufficientStorage(freeBytes: free, requiredBytes: needed)
            phase = .failed(ModelDownloadFailureReason(error: error))
            throw error
        }

        let staging = root.appendingPathComponent(
            ".download-\(Self.modelID)-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        phase = .downloading(fraction: 0)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let total = max(sizeBytes, 1)
            var completed: Int64 = 0
            for file in pins.files {
                try Task.checkCancellation()
                guard Self.isSafeRelativePath(file.path) else {
                    throw LocalModelManagerError.integrityFileMissing(file.path)
                }
                let done = completed
                let temporary = try await fetch(
                    Self.url(repository: pins.repository, revision: pins.revision, path: file.path)
                ) { [weak self] written in
                    Task { @MainActor [weak self] in
                        guard let self, case let .downloading(current) = self.phase else { return }
                        let fraction = Double(done + written) / Double(total)
                        if fraction > current { self.phase = .downloading(fraction: min(fraction, 0.99)) }
                    }
                }
                defer { try? fileManager.removeItem(at: temporary) }
                try Task.checkCancellation()
                try await Task.detached(priority: .userInitiated) {
                    try LocalModelIntegrity.verify(
                        file: temporary, against: file, modelIdentifier: GrammarModelStore.modelID
                    )
                }.value
                let destination = staging.appendingPathComponent(file.path)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: temporary, to: destination)
                completed += file.size
                phase = .downloading(fraction: min(Double(completed) / Double(total), 0.99))
            }
            // A delete or cancel that landed during the last file's hash is
            // only seen here; nothing below may run after one.
            try Task.checkCancellation()
            guard started == generation else { throw CancellationError() }
            // Each file was hashed as it landed; only the set is left.
            try LocalModelIntegrity.verifySizes(in: staging, files: pins.files, requiringMarker: false)
            try LocalModelIntegrity.writeMarker(LocalModelIntegrity.fingerprint(of: pins.files), in: staging)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.moveItem(at: staging, to: directory)
            try LocalModelIntegrity.verifySizes(in: directory, files: pins.files)
            phase = .ready
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                phase = isReady ? .ready : .absent
                throw CancellationError()
            }
            // `ModelDownloadFailureReason` does not map a checksum failure;
            // here it is the case that most needs saying plainly.
            phase = .failed(error is LocalModelIntegrityError ? .damaged : ModelDownloadFailureReason(error: error))
            throw error
        }
    }

    nonisolated static func url(repository: String, revision: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(path)"
        components.queryItems = [URLQueryItem(name: "download", value: "true")]
        return components.url!
    }

    private nonisolated static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return !components.isEmpty && components.allSatisfy { $0 != "." && $0 != ".." }
    }

    // MARK: - Transfer

    /// Up to three attempts on the shared session, carrying resume data across
    /// a dropped connection.
    nonisolated static let urlSessionFetch: Fetch = { url, progress in
        var resumeData: Data?
        for attempt in 1...3 {
            try Task.checkCancellation()
            do {
                return try await transfer(url: url, resumeData: resumeData, progress: progress)
            } catch {
                let retryable: Bool = switch (error as? URLError)?.code {
                case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                     .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                    true
                default:
                    false
                }
                guard attempt < 3, retryable else { throw error }
                resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                try await Task.sleep(nanoseconds: UInt64(attempt) * 750_000_000)
            }
        }
        throw URLError(.cannotLoadFromNetwork)
    }

    /// The transfer and its cancellation, which arrive on different threads
    /// and in either order.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var observation: NSKeyValueObservation?
        private var cancelled = false
        private var resumed = false

        /// Keeps `task`, unless cancellation already happened: then it is
        /// cancelled at once and this returns false.
        func install(_ task: URLSessionDownloadTask, observation: NSKeyValueObservation) -> Bool {
            let keep = lock.withLock { () -> Bool in
                guard !cancelled else { return false }
                self.task = task
                self.observation = observation
                return true
            }
            if !keep {
                observation.invalidate()
                task.cancel()
            }
            return keep
        }

        func cancel() {
            let task = lock.withLock { () -> URLSessionDownloadTask? in
                cancelled = true
                return self.task
            }
            task?.cancel()
        }

        /// True exactly once, so the continuation is resumed once.
        func claimResume() -> Bool {
            lock.withLock {
                defer { resumed = true }
                observation?.invalidate()
                return !resumed
            }
        }
    }

    private nonisolated static func transfer(
        url: URL,
        resumeData: Data?,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let completion: @Sendable (URL?, URLResponse?, Error?) -> Void = { location, response, error in
                    guard box.claimResume() else { return }
                    if let error { return continuation.resume(throwing: error) }
                    guard let location, let http = response as? HTTPURLResponse else {
                        return continuation.resume(throwing: URLError(.badServerResponse))
                    }
                    guard 200..<300 ~= http.statusCode else {
                        return continuation.resume(throwing: LocalModelManagerError.downloadFailed(
                            path: url.lastPathComponent, statusCode: http.statusCode
                        ))
                    }
                    // The session deletes `location` when this returns.
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent("grammar-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: kept)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let task = if let resumeData {
                    URLSession.shared.downloadTask(withResumeData: resumeData, completionHandler: completion)
                } else {
                    URLSession.shared.downloadTask(with: url, completionHandler: completion)
                }
                let observation = task.observe(\.countOfBytesReceived) { task, _ in
                    progress(task.countOfBytesReceived)
                }
                guard box.install(task, observation: observation) else {
                    if box.claimResume() { continuation.resume(throwing: CancellationError()) }
                    return
                }
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}
