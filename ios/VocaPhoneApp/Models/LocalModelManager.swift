import AVFAudio
import Foundation
import Observation
import UIKit
@preconcurrency import WhisperKit

@MainActor
@Observable
final class LocalModelManager {
    /// A background `URLSession` is identified by the containing app, not by a
    /// particular SwiftUI screen. Keeping this stable lets iOS own the active
    /// transfer while VocaPhone is suspended and reconnect the session when the
    /// app is awakened for background events.
    nonisolated static var backgroundDownloadSessionIdentifier: String {
        "\(Bundle.main.bundleIdentifier ?? "com.vocahq.vocaphone").model-downloads"
    }

    private(set) var downloadedModelIDs: Set<String> = []
    /// Per-model transfers in flight. Two can run at once; a third Get waits.
    private(set) var inFlightDownloads: [String: InFlightDownload] = [:]
    /// Models that tapped Get while both slots were busy, in tap order.
    private(set) var queuedModelIDs: [String] = []

    struct InFlightDownload: Equatable, Sendable {
        var fraction: Double
        var totalBytes: Int64
        var startedAt: Date
    }

    var downloadingModelIDs: Set<String> { Set(inFlightDownloads.keys) }

    func isDownloading(_ id: String) -> Bool { inFlightDownloads[id] != nil }
    func isQueued(_ id: String) -> Bool { queuedModelIDs.contains(id) }
    func progress(for id: String) -> Double { inFlightDownloads[id]?.fraction ?? 0 }

    /// First in-flight id, for surfaces that still show a single transfer.
    var downloadingModelID: String? { inFlightDownloads.keys.sorted().first }

    var progress: Double {
        guard let id = downloadingModelID else { return 0 }
        return progress(for: id)
    }

    var downloadTotalBytes: Int64 { inFlightDownloads[downloadingModelID ?? ""]?.totalBytes ?? 0 }
    var downloadStartedAt: Date? { inFlightDownloads[downloadingModelID ?? ""]?.startedAt }

    var downloadedBytes: Int64 {
        guard let id = downloadingModelID, let item = inFlightDownloads[id], item.totalBytes > 0 else {
            return 0
        }
        return Int64(item.fraction * Double(item.totalBytes))
    }

    var downloadSizeProgress: String? { downloadingModelID.flatMap { downloadSizeProgress(for: $0) } }

    var downloadTimeRemaining: String? { downloadingModelID.flatMap { downloadTimeRemaining(for: $0) } }

    func downloadSizeProgress(for id: String) -> String? {
        guard let item = inFlightDownloads[id], item.totalBytes > 0 else { return nil }
        return DownloadReadiness.sizeProgress(
            downloadedBytes: Int64(item.fraction * Double(item.totalBytes)),
            totalBytes: item.totalBytes
        )
    }

    /// The estimate without its trailing "left", for a sentence that puts it
    /// somewhere other than the end.
    func downloadTimeRemainingPhrase(for id: String) -> String? {
        guard let item = inFlightDownloads[id] else { return nil }
        return DownloadReadiness.timeRemainingPhrase(
            downloadedBytes: Int64(item.fraction * Double(max(item.totalBytes, 1))),
            totalBytes: item.totalBytes,
            elapsed: Date().timeIntervalSince(item.startedAt)
        )
    }

    func downloadTimeRemaining(for id: String) -> String? {
        guard let item = inFlightDownloads[id] else { return nil }
        return DownloadReadiness.timeRemaining(
            downloadedBytes: Int64(item.fraction * Double(max(item.totalBytes, 1))),
            totalBytes: item.totalBytes,
            elapsed: Date().timeIntervalSince(item.startedAt)
        )
    }

    /// Free space on the volume models are written to, or 0 when unreadable.
    var availableStorageBytes: Int64 {
        guard let modelsDirectory else { return 0 }
        return DownloadReadiness.availableStorageBytes(at: modelsDirectory)
    }
    private(set) var loadingModelID: String?
    private(set) var loadingMessage: String?
    private(set) var message: String?
    private(set) var hasError = false
    /// Models whose files are present but whose SHA-256 digests are still being
    /// checked. Published because "downloaded" and "safe to load" are different
    /// claims, and the picker must not offer the second before it is true.
    private(set) var verifyingModelIDs: Set<String> = []
    /// Models whose files are present but failed their integrity check. A
    /// corrupted or tampered-with model is a different problem from a download
    /// that never happened, and it needs a different sentence.
    private(set) var failedIntegrityModelIDs: Set<String> = []

#if DEBUG
    /// True only for a manager built by the preview initializer below. A canvas
    /// is live, so without this a tap on Download in a preview would fetch a
    /// gigabyte from Hugging Face, and Delete would remove a real model.
    private(set) var isPreviewFixture = false
#endif

    /// Whether this instance declines to touch the network or the filesystem.
    /// Always `false` outside DEBUG.
    private var isInert: Bool {
#if DEBUG
        isPreviewFixture
#else
        false
#endif
    }

    private var whisperKit: WhisperKit?
    private var sherpaRecognizer: SherpaRecognizer?
    private var loadedModelID: String?

    private var loadedLanguage: String?
    /// Canary bakes source and target into the recognizer exactly as it bakes
    /// the language, so a change of translation target has to rebuild it too.
    /// Empty means transcribe.
    private var loadedTranslateTo = ""
    /// Sherpa only: WhisperKit takes its decoding options per call, so quality
    /// never invalidates a loaded Whisper model.
    private var loadedQuality: TranscriptionQuality?
    /// The sherpa load currently running, so a second request waits for it
    /// instead of building a second ONNX graph beside the first.
    private var sherpaLoad: Task<SherpaRecognizer, Error>?
    /// Download ownership belongs to the manager rather than the picker view.
    /// SwiftUI is free to recreate either onboarding or Settings while a model
    /// is downloading; a view-local task handle made their Cancel buttons lose
    /// the operation they were meant to stop.
    @ObservationIgnored private var modelDownloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var queuedDownloads:
        [(descriptor: LocalModelDescriptor, onCompletion: @MainActor () -> Void)] = []

    /// Downloads run on a foreground session while the app is in front, and are
    /// handed to the background session only when the user leaves. Routing every
    /// byte through `nsurlsessiond` costs real throughput, and the app is in
    /// front for very nearly every download.
    private static let downloadDelegate = FileDownloadDelegate()

    /// Two full models at once. Files inside one model still use `maxParallelTransfers`.
    static let maxConcurrentModelDownloads = ModelDownloadStartDecision.maxConcurrent

    /// How many of a model's small files are fetched side by side.
    static let maxParallelTransfers = 4

    /// Files at or above this size are fetched one at a time rather than
    /// alongside their siblings, so the handful of very large weights in a model
    /// never compete with each other for the link.
    private static let largeFileThreshold: Int64 = 32 * 1024 * 1024

    private static let foregroundDownloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15 * 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = maxParallelTransfers
        // Model files are verified and stored by hand. Nothing this large has
        // any business entering the shared URL cache on the way past.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: downloadDelegate,
            delegateQueue: nil
        )
    }()

    private static let backgroundDownloadSession: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: backgroundDownloadSessionIdentifier
        )
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15 * 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // Model downloads are explicitly user-initiated. Low Data Mode and an
        // expensive connection should not silently pause a download the user
        // has already chosen to make.
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        return URLSession(
            configuration: configuration,
            delegate: downloadDelegate,
            delegateQueue: nil
        )
    }()

    /// Holds the app awake just long enough to hand every in-flight transfer to
    /// the background session. Without it the process can suspend mid-handoff
    /// and the download is lost rather than continued.
    private final class BackgroundAssertion: @unchecked Sendable {
        private let lock = NSLock()
        private var identifier: UIBackgroundTaskIdentifier = .invalid

        @MainActor
        func begin() {
            let identifier = UIApplication.shared.beginBackgroundTask(
                withName: "model-download-handoff"
            ) { [weak self] in
                self?.end()
            }
            lock.lock()
            self.identifier = identifier
            lock.unlock()
        }

        func end() {
            lock.lock()
            let identifier = self.identifier
            self.identifier = .invalid
            lock.unlock()
            guard identifier != .invalid else { return }
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
    }

    /// Moves anything in flight onto the background session so leaving the app
    /// does not kill a half-finished 1.5 GB download. Called from the scene
    /// phase hook in `VocaPhoneApp`.
    ///
    /// There is deliberately no move back on return to the foreground: undoing
    /// it means cancelling a live task and hoping for resume data, and a
    /// transfer that cannot produce any would restart from zero.
    @MainActor
    static func enterBackground() {
#if DEBUG
        ModelDownloadTrace.record("app.background", "transfers=\(downloadDelegate.hasTransfers)")
#endif
        // This runs on every trip to the home screen, so do not take a
        // background assertion unless there is actually a transfer to hand over.
        guard downloadDelegate.hasTransfers else { return }
        let assertion = BackgroundAssertion()
        assertion.begin()
        downloadDelegate.migrate(to: backgroundDownloadSession) {
            assertion.end()
        }
    }

    private var modelsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("LocalModels", isDirectory: true)
    }

    /// Tokenizers live outside the model folders because several model sizes map
    /// onto the same tokenizer repository.
    private var tokenizersDirectory: URL? {
        modelsDirectory?.appendingPathComponent("Tokenizers", isDirectory: true)
    }

    init() {
        // Recreate the session at launch so iOS can reconnect any background
        // events belonging to the stable identifier above.
        _ = Self.backgroundDownloadSession
        removeAbandonedStaging()
        refresh()
#if DEBUG
        ModelDownloadTrace.record(
            "manager.init",
            "interrupted=\(Self.interruptedDownloadIDs.joined(separator: ","))"
        )
#endif
        // Inherit before resuming: a download restarted ahead of this would
        // not know the system was already fetching its largest file.
        Task { @MainActor [weak self] in
            await Self.downloadDelegate.inheritTransfers(from: Self.backgroundDownloadSession)
            self?.resumeInterruptedDownloads()
        }
    }

    /// Makes a resumed download the model in use, unless something else
    /// already is. Mirrors what the picker does when a download it started
    /// finishes while it is still on screen.
    private func adoptResumedModel(_ descriptor: LocalModelDescriptor) {
        let id = descriptor.id
        guard isDownloaded(id), !failedIntegrityModelIDs.contains(id) else { return }
        if let inUse = LocalTranscriptionPreferences.modelIdentifier,
           inUse != id,
           isDownloaded(inUse),
           !failedIntegrityModelIDs.contains(inUse)
        {
            return
        }
        LocalTranscriptionPreferences.modelIdentifier = id
        LocalTranscriptionPreferences.enabled = true
#if DEBUG
        ModelDownloadTrace.record("adopt.ok", id)
#endif
        let language = ModelLanguageSupport.resolve(
            KeyboardPreferences.transcriptionLanguage,
            modelLanguages: descriptor.selectableLanguageCodes
        )
        Task { [weak self] in
            try? await self?.prepare(descriptor, language: language.rawValue)
        }
    }

    /// Build folders left by a process that died mid-download.
    ///
    /// Each download assembles into its own `.download-<model>-<uuid>` (and
    /// each tokenizer into `.tokenizer-<uuid>`) and removes it when it ends —
    /// in a `defer`, which a terminated process never reaches. A resumed
    /// download builds into a fresh folder, so the old one stays for good:
    /// one more after every trip to Settings that changed Full Access mid-way.
    /// Nothing in this process can be downloading yet, so anything found here
    /// belongs to a process that is gone.
    private func removeAbandonedStaging() {
        let manager = FileManager.default
        for (directory, prefix) in [(modelsDirectory, ".download-"), (tokenizersDirectory, ".tokenizer-")] {
            guard let directory else { continue }
            let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasPrefix(prefix) {
                Self.removeItemLater(directory.appendingPathComponent(name))
            }
        }
    }

    /// Model ids that had a download running when this process started.
    ///
    /// Written durably because the answer has to outlive the process: iOS
    /// terminates suspended apps routinely, which is the whole reason the
    /// background session exists. The transfer survives that; the `download`
    /// call assembling the model does not, so without this nothing claims the
    /// finished files, nothing reports a failure, and the model quietly never
    /// appears.
    private static var interruptedDownloadIDs: [String] {
        get { KeyboardPreferences.defaults?.stringArray(forKey: interruptedKey) ?? [] }
        set {
            if newValue.isEmpty {
                KeyboardPreferences.defaults?.removeObject(forKey: interruptedKey)
            } else {
                KeyboardPreferences.defaults?.set(newValue, forKey: interruptedKey)
            }
        }
    }

    private static let interruptedKey = "localModels.downloadsInFlight"

    private static func rememberDownload(_ id: String) {
        var ids = interruptedDownloadIDs
        guard !ids.contains(id) else { return }
        ids.append(id)
        interruptedDownloadIDs = ids
    }

    private static func forgetDownload(_ id: String) {
        interruptedDownloadIDs = interruptedDownloadIDs.filter { $0 != id }
    }

    /// Picks up whatever the last process was in the middle of.
    ///
    /// Only a process that went away leaves an entry: a download that finishes,
    /// fails or is cancelled clears its own. Restarting is cheap — the files
    /// already on disk are claimed from the inbox rather than fetched again.
    private func resumeInterruptedDownloads() {
        let interrupted = Self.interruptedDownloadIDs
        guard !interrupted.isEmpty else { return }
        for id in interrupted {
            guard let descriptor = LocalModelCatalog.descriptor(for: id) else {
                Self.forgetDownload(id)
                continue
            }
            guard !isDownloaded(id) else {
                Self.forgetDownload(id)
                continue
            }
            // With the completion, not without it. The one that used to claim
            // the selection lived in the picker and died with the process, so
            // a resumed download landed the files on disk and left nothing
            // pointing at them: the flow stayed blocked on a model it already
            // had, and dictation said it had none.
#if DEBUG
            ModelDownloadTrace.record("model.resume", id)
#endif
            startDownload(descriptor) { [weak self] in
                self?.adoptResumedModel(descriptor)
            }
        }
    }

#if DEBUG
    /// A manager frozen in one state, for `#Preview` only.
    ///
    /// The designated initializer stats every catalog entry and can start a
    /// background hashing pass, so a canvas built on it would show whatever
    /// this developer happens to have downloaded — which is never the state
    /// being previewed, and never the interesting ones: verifying, loading, or
    /// failed integrity.
    init(
        preview downloaded: Set<String> = [],
        downloading: String? = nil,
        progress: Double = 0,
        loading: String? = nil,
        loadingMessage: String? = nil,
        verifying: Set<String> = [],
        failedIntegrity: Set<String> = [],
        message: String? = nil,
        hasError: Bool = false
    ) {
        isPreviewFixture = true
        downloadedModelIDs = downloaded
        if let downloading {
            inFlightDownloads[downloading] = InFlightDownload(
                fraction: progress,
                totalBytes: 0,
                startedAt: Date()
            )
        }
        loadingModelID = loading
        self.loadingMessage = loadingMessage
        verifyingModelIDs = verifying
        failedIntegrityModelIDs = failedIntegrity
        self.message = message
        self.hasError = hasError
    }
#endif

    /// Stat-only pass, safe to run on the main actor during launch.
    func refresh() {
        var verified: Set<String> = []
        var needsDigestCheck: [LocalModelDescriptor] = []
        for descriptor in LocalModelCatalog.all {
            switch inspect(descriptor) {
            case .verified: verified.insert(descriptor.id)
            case .presentButUnverified: needsDigestCheck.append(descriptor)
            case .missing: break
            }
        }
        downloadedModelIDs = verified
        verifyingModelIDs = Set(needsDigestCheck.map(\.id))
        failedIntegrityModelIDs.subtract(verified)
        guard !needsDigestCheck.isEmpty else { return }
        // A model downloaded before markers existed, or one whose pins changed in
        // an app update, is hashed once in the background rather than on launch.
        Task { await self.verifyInBackground(needsDigestCheck) }
    }

    private enum Inspection {
        case verified
        case presentButUnverified
        case missing
    }

    /// Tracks bytes across every transfer in flight so the picker shows real
    /// movement rather than a step per finished file. A unit is one file, or one
    /// byte range within a large file, and several run at once.
    private actor DownloadProgress {
        let totalBytes: Int64
        private var completedBytes: Int64 = 0
        private var inFlight: [UUID: Int64] = [:]

        init(totalBytes: Int64) {
            self.totalBytes = totalBytes
        }

        func addCompleted(_ bytes: Int64) -> Double {
            completedBytes += max(0, bytes)
            return fraction
        }

        func begin(_ unit: UUID) {
            inFlight[unit] = 0
        }

        /// Returns nil for a unit that has already finished or been abandoned,
        /// so a late delegate callback cannot resurrect its bytes.
        func update(_ unit: UUID, bytesWritten: Int64, expectedBytes: Int64) -> Double? {
            guard inFlight[unit] != nil else { return nil }
            inFlight[unit] = min(max(0, bytesWritten), max(0, expectedBytes))
            return fraction
        }

        func complete(_ unit: UUID, bytes: Int64) -> Double {
            inFlight.removeValue(forKey: unit)
            completedBytes += max(0, bytes)
            return fraction
        }

        /// A retry restarts the unit, so its bytes go back to zero.
        func reset(_ unit: UUID) -> Double {
            if inFlight[unit] != nil { inFlight[unit] = 0 }
            return fraction
        }

        private var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            let active = inFlight.values.reduce(Int64(0), +)
            return min(1, Double(completedBytes + active) / Double(totalBytes))
        }
    }

    /// A download task writes into a system-managed temporary file instead of
    /// delivering one byte at a time through an AsyncBytes data task. This is
    /// important for multi-hundred-megabyte Core ML weights: the old path made
    /// every byte cross back through the main actor before it could be written.
    ///
    /// One delegate serves both sessions, so transfers are keyed by a token
    /// carried in `taskDescription`. `taskIdentifier` is only unique within a
    /// single session and would collide across the two.
    private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate,
        @unchecked Sendable {
        /// Progress is forwarded at most this often, and only once a meaningful
        /// slice of the unit has landed. `didWriteData` fires per network chunk;
        /// forwarding every one of them put tens of thousands of hops on the
        /// main actor over a single gigabyte-scale file and re-rendered the
        /// picker each time.
        private static let progressInterval: TimeInterval = 0.1

        private struct TransferIdentity: Codable {
            var token: String
            /// `<model id>:<path in the repo>`, which is what makes a retained
            /// file findable again — see `downloadUnit` for why it is the whole
            /// path and not the file name.
            ///
            /// This used to be the request URL, and the hosts these weights
            /// come from sign their links: every request carries a fresh
            /// `Expires`, `Policy` and `Signature`. Two requests for the same
            /// file never produce the same string, so a lookup by URL could
            /// not match even in principle — the whole inbox was write-only,
            /// and a 600 MB file that had finished downloading was fetched
            /// again from zero.
            var key: String
            var statusCode: Int?
        }

        private struct Transfer {
            var task: URLSessionDownloadTask
            let request: URLRequest
            let expectedBytes: Int64
            let continuation: CheckedContinuation<(URL, URLResponse), Error>
            let progressHandler: @Sendable (Int64) -> Void
            var lastReportedBytes: Int64 = 0
            var lastReportedAt: TimeInterval = 0
            /// Set while a task is cancelled only so it can be restarted on the
            /// other session. Its cancellation must not fail the continuation.
            var isMigrating = false

            /// At most a couple of hundred updates per unit, never more often
            /// than once a megabyte.
            var progressThreshold: Int64 {
                max(1_048_576, expectedBytes / 200)
            }
        }

        private let lock = NSLock()
        private var transfers: [String: Transfer] = [:]
        /// Background transfers this process inherited, by `<model>/<file>`.
        ///
        /// A terminated app leaves its downloads running in the background
        /// session; the next launch gets them back from `allTasks`. Without
        /// this the resumed download starts a second request for a file the
        /// system is already fetching, and the same weights come down twice.
        private var inheritedTransfers: [String: URLSessionDownloadTask] = [:]

        /// Reads back whatever the background session is still running.
        /// Call once, before any download is started.
        func inheritTransfers(from session: URLSession) async {
            // The lock is taken in `store`, not here: `NSLock` may not be held
            // across a suspension point.
            let tasks = await session.allTasks
#if DEBUG
            ModelDownloadTrace.record(
                "inherit.tasks",
                "n=\(tasks.count) states=\(tasks.map { String($0.state.rawValue) }.joined(separator: ","))"
            )
#endif
            store(inherited: tasks)
        }

        private func store(inherited tasks: [URLSessionTask]) {
            lock.lock()
            defer { lock.unlock() }
            let items = dropRetiredIdentitiesLocked()
            var found: [String: URLSessionDownloadTask] = [:]
            for task in tasks {
                guard let download = task as? URLSessionDownloadTask,
                      task.state == .running || task.state == .suspended,
                      let token = task.taskDescription,
                      let identity = items[token]
                else { continue }
                found[identity.key] = download
            }
            inheritedTransfers = found
        }

        /// Forgets transfers recorded under a key format this build no longer
        /// writes, and deletes whatever file each one left in the inbox.
        ///
        /// An entry keyed by URL, or by file name alone, can never be claimed
        /// again — the lookups no longer produce those strings — so its file
        /// would sit in the inbox for good. One of them was a finished 622 MB
        /// weight. Every current key has a `:` between model and path.
        ///
        /// It also clears files the index no longer names at all. Renaming a
        /// field of `TransferIdentity` made the older index undecodable, and
        /// `loadIndexLocked` reads the index whole: one entry it cannot read
        /// empties all of it, leaving every file behind with nothing pointing
        /// at it and nothing that would ever delete it.
        private func dropRetiredIdentitiesLocked() -> [String: TransferIdentity] {
            var items = loadIndexLocked()
            let retired = items.filter { !$0.value.key.contains(":") }
            for token in retired.keys {
                items.removeValue(forKey: token)
                try? FileManager.default.removeItem(
                    at: Self.inboxDirectory.appendingPathComponent(token)
                )
            }
            if !retired.isEmpty { saveIndexLocked(items) }

            let manager = FileManager.default
            let files = (try? manager.contentsOfDirectory(atPath: Self.inboxDirectory.path)) ?? []
            for name in files
                where name != Self.indexURL.lastPathComponent && items[name] == nil
            {
                try? manager.removeItem(at: Self.inboxDirectory.appendingPathComponent(name))
            }
            return items
        }

        private func takeInherited(_ key: String) -> URLSessionDownloadTask? {
            lock.lock()
            defer { lock.unlock() }
            return inheritedTransfers.removeValue(forKey: key)
        }

        func start(
            session: URLSession,
            request: URLRequest,
            expectedBytes: Int64,
            resumeData: Data?,
            key: String,
            progressHandler: @escaping @Sendable (Int64) -> Void
        ) async throws -> (URL, URLResponse) {
            // A transfer inherited from the last process is already most of
            // the way through this exact file. Waiting on it costs nothing;
            // starting a second request for it costs the whole file again.
            let inherited = takeInherited(key)
#if DEBUG
            ModelDownloadTrace.record("unit.start", "\(key) inherited=\(inherited != nil)")
#endif
            let token = inherited?.taskDescription ?? UUID().uuidString
            if inherited == nil {
                persistIdentity(token: token, key: key)
            }
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
                    lock.lock()
                    let task = inherited
                        ?? resumeData.map(session.downloadTask(withResumeData:))
                        ?? session.downloadTask(with: request)
                    task.taskDescription = token
                    transfers[token] = Transfer(
                        task: task,
                        request: request,
                        expectedBytes: expectedBytes,
                        continuation: continuation,
                        progressHandler: progressHandler
                    )
                    let isCancelled = Task.isCancelled
                    lock.unlock()

                    if isCancelled {
                        task.cancel()
                    } else if inherited == nil || task.state == .suspended {
                        // An inherited task is already running; resuming a
                        // running task is harmless but resuming a suspended
                        // one is the point.
                        task.resume()
                    }
                }
            }, onCancel: { [weak self] in
                self?.cancel(token: token)
            })
        }

        var hasTransfers: Bool {
            lock.lock()
            let hasTransfers = !transfers.isEmpty
            lock.unlock()
            return hasTransfers
        }

        /// Cancels every transfer. Used by the picker's Cancel button, which
        /// stops the whole model rather than one file.
        func cancel() {
            lock.lock()
            let tasks = transfers.values.map(\.task)
            lock.unlock()
            tasks.forEach { $0.cancel() }
        }

        private func cancel(token: String) {
            lock.lock()
            let task = transfers[token]?.task
            lock.unlock()
            task?.cancel()
        }

        /// Cancels every in-flight transfer for its resume data and restarts it
        /// on `session`, keeping the awaiting continuation intact. A transfer
        /// that cannot produce resume data restarts from the beginning rather
        /// than being dropped: losing bytes beats losing the download.
        func migrate(to session: URLSession, completion: @escaping @Sendable () -> Void) {
            lock.lock()
            var pending: [String: URLSessionDownloadTask] = [:]
            for (token, transfer) in transfers where !transfer.isMigrating {
                transfers[token]?.isMigrating = true
                pending[token] = transfer.task
            }
            lock.unlock()

            guard !pending.isEmpty else {
                completion()
                return
            }

            let group = DispatchGroup()
            for (token, task) in pending {
                group.enter()
                task.cancel(byProducingResumeData: { [weak self] resumeData in
                    self?.restart(token: token, on: session, resumeData: resumeData)
                    group.leave()
                })
            }
            group.notify(queue: .main) { completion() }
        }

        private func restart(token: String, on session: URLSession, resumeData: Data?) {
            lock.lock()
            guard var transfer = transfers[token] else {
                lock.unlock()
                return
            }
            let task = resumeData.map(session.downloadTask(withResumeData:))
                ?? session.downloadTask(with: transfer.request)
            task.taskDescription = token
            transfer.task = task
            transfer.isMigrating = false
            // Without resume data the new task counts from zero again, so a
            // high-water mark carried over from the old one would suppress every
            // report until it caught up.
            transfer.lastReportedBytes = 0
            transfer.lastReportedAt = 0
            transfers[token] = transfer
            lock.unlock()
            task.resume()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            report(totalBytesWritten, token: downloadTask.taskDescription)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            guard let token = downloadTask.taskDescription else { return }
            guard isTracking(token) else {
                // The process died after iOS accepted the transfer. Keep the
                // file under its token so the next `downloadUnit` can claim it
                // instead of dropping a finished weight on the floor.
                retainOrphan(
                    token: token,
                    from: location,
                    response: downloadTask.response
                )
                return
            }
            let persistentLocation = FileManager.default.temporaryDirectory
                .appendingPathComponent("vocaphone-download-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: persistentLocation)
                finish(
                    token: token,
                    result: .success((persistentLocation, downloadTask.response ?? URLResponse()))
                )
            } catch {
                finish(token: token, result: .failure(error))
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            guard let error, let token = task.taskDescription else { return }
            lock.lock()
            let transfer = transfers[token]
            lock.unlock()
            // A migration cancels the task on purpose, and URLSession does not
            // promise whether this callback or the resume-data handler runs
            // first. Both orderings have to be ignored: still migrating, or
            // already replaced by the task `restart` put in its place.
            guard let transfer, transfer.task === task, !transfer.isMigrating else { return }
            finish(token: token, result: .failure(error))
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            guard let identifier = session.configuration.identifier else { return }
            ModelDownloadBackgroundEvents.shared.finish(identifier: identifier)
        }

        private func isTracking(_ token: String) -> Bool {
            lock.lock()
            let isTracking = transfers[token] != nil
            lock.unlock()
            return isTracking
        }

        private func report(_ totalBytesWritten: Int64, token: String?) {
            guard let token else { return }
            let now = Date().timeIntervalSinceReferenceDate
            lock.lock()
            guard var transfer = transfers[token] else {
                lock.unlock()
                return
            }
            let shouldReport =
                totalBytesWritten - transfer.lastReportedBytes >= transfer.progressThreshold
                && now - transfer.lastReportedAt >= Self.progressInterval
            if shouldReport {
                transfer.lastReportedBytes = totalBytesWritten
                transfer.lastReportedAt = now
                transfers[token] = transfer
            }
            let progressHandler = transfer.progressHandler
            lock.unlock()
            if shouldReport { progressHandler(totalBytesWritten) }
        }

        private func finish(
            token: String,
            result: Result<(URL, URLResponse), Error>
        ) {
            lock.lock()
            let transfer = transfers.removeValue(forKey: token)
            lock.unlock()
            clearIdentity(token: token)
            transfer?.continuation.resume(with: result)
        }

        /// A file that finished after this process died. Matched by source URL
        /// on the next `downloadUnit` for the same request.
        func claimFinishedFile(key: String, expectedBytes: Int64) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            var items = loadIndexLocked()
            guard let match = items.first(where: { $0.value.key == key })
            else { return nil }
            let file = Self.inboxDirectory.appendingPathComponent(match.key)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            // A retained file is only worth claiming whole. A truncated one
            // would pass every later check by being the right name.
            if expectedBytes > 0 {
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size]
                guard (size as? NSNumber)?.int64Value == expectedBytes else {
                    try? FileManager.default.removeItem(at: file)
                    items.removeValue(forKey: match.key)
                    saveIndexLocked(items)
                    return nil
                }
            }
            if let code = match.value.statusCode, !(200..<300).contains(code) {
                try? FileManager.default.removeItem(at: file)
                items.removeValue(forKey: match.key)
                saveIndexLocked(items)
                return nil
            }
            items.removeValue(forKey: match.key)
            saveIndexLocked(items)
            return file
        }

        private static var inboxDirectory: URL {
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("LocalModels/DownloadInbox", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        private static var indexURL: URL {
            inboxDirectory.appendingPathComponent("index.json")
        }

        private func persistIdentity(token: String, key: String) {
            lock.lock()
            defer { lock.unlock() }
            var items = loadIndexLocked()
            items[token] = TransferIdentity(token: token, key: key, statusCode: nil)
            saveIndexLocked(items)
        }

        private func retainOrphan(
            token: String,
            from location: URL,
            response: URLResponse?
        ) {
            lock.lock()
            defer { lock.unlock() }
            var items = loadIndexLocked()
            let destination = Self.inboxDirectory.appendingPathComponent(token)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                if var identity = items[token] {
                    identity.statusCode = (response as? HTTPURLResponse)?.statusCode
                    items[token] = identity
                    saveIndexLocked(items)
                }
            } catch {
                return
            }
        }

        private func clearIdentity(token: String) {
            lock.lock()
            defer { lock.unlock() }
            var items = loadIndexLocked()
            items.removeValue(forKey: token)
            saveIndexLocked(items)
            let leftover = Self.inboxDirectory.appendingPathComponent(token)
            try? FileManager.default.removeItem(at: leftover)
        }

        private func loadIndexLocked() -> [String: TransferIdentity] {
            guard let data = try? Data(contentsOf: Self.indexURL),
                  let items = try? JSONDecoder().decode(
                    [String: TransferIdentity].self,
                    from: data
                  )
            else { return [:] }
            return items
        }

        private func saveIndexLocked(_ items: [String: TransferIdentity]) {
            guard let data = try? JSONEncoder().encode(items) else { return }
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    private func inspect(_ descriptor: LocalModelDescriptor) -> Inspection {
        guard let folder = modelDirectory(for: descriptor.id) else { return .missing }
        switch descriptor.engine {
        case .whisperKit:
            guard let tokenizerRepository = descriptor.tokenizerRepository,
                  let files = try? LocalModelIntegrity.files(for: descriptor.id),
                  let tokenizer = try? LocalModelIntegrity.tokenizer(for: tokenizerRepository),
                  let tokenizerFolder = tokenizerDirectory(for: tokenizerRepository)
            else { return .missing }
            do {
                try LocalModelIntegrity.verifySizes(in: folder, files: files, requiringMarker: false)
                try LocalModelIntegrity.verifySizes(
                    in: tokenizerFolder, files: tokenizer.files, requiringMarker: false
                )
            } catch {
                return .missing
            }
            let verified = LocalModelIntegrity.markerMatches(
                LocalModelIntegrity.fingerprint(of: files), in: folder
            ) && LocalModelIntegrity.markerMatches(
                LocalModelIntegrity.fingerprint(of: tokenizer.files), in: tokenizerFolder
            )
            return verified ? .verified : .presentButUnverified
        case .sherpaOnnx:
            guard let files = try? LocalModelIntegrity.sherpaModel(for: descriptor.id).files
            else { return .missing }
            do {
                try LocalModelIntegrity.verifySizes(in: folder, files: files, requiringMarker: false)
            } catch {
                return .missing
            }
            return LocalModelIntegrity.markerMatches(
                LocalModelIntegrity.fingerprint(of: files), in: folder
            ) ? .verified : .presentButUnverified
        }
    }

    private func verifyInBackground(_ descriptors: [LocalModelDescriptor]) async {
        for descriptor in descriptors {
            guard let folder = modelDirectory(for: descriptor.id) else { continue }
            let identifier = descriptor.id
            let whisperTokenizerFolder = descriptor.tokenizerRepository.flatMap {
                tokenizerDirectory(for: $0)
            }
            let verified = await Task.detached(priority: .utility) {
                switch descriptor.engine {
                case .whisperKit:
                    guard let tokenizerRepository = descriptor.tokenizerRepository,
                          let files = try? LocalModelIntegrity.files(for: identifier),
                          let tokenizer = try? LocalModelIntegrity.tokenizer(
                              for: tokenizerRepository
                          ),
                          let tokenizerFolder = whisperTokenizerFolder
                    else { return false }
                    return (try? LocalModelIntegrity.verifyDigests(
                        in: folder, files: files, modelIdentifier: identifier
                    )) != nil && (try? LocalModelIntegrity.verifyDigests(
                        in: tokenizerFolder, files: tokenizer.files, modelIdentifier: identifier
                    )) != nil
                case .sherpaOnnx:
                    guard let files = try? LocalModelIntegrity.sherpaModel(
                        for: identifier
                    ).files else { return false }
                    return (try? LocalModelIntegrity.verifyDigests(
                        in: folder, files: files, modelIdentifier: identifier
                    )) != nil
                }
            }.value
            verifyingModelIDs.remove(identifier)
            if verified {
                downloadedModelIDs.insert(identifier)
                failedIntegrityModelIDs.remove(identifier)
            } else {
                downloadedModelIDs.remove(identifier)
                // The files are on disk and do not match their pins. Saying only
                // "not downloaded" would send the user to re-download something
                // they already have.
                failedIntegrityModelIDs.insert(identifier)
            }
        }
    }

    func isDownloaded(_ id: String) -> Bool { downloadedModelIDs.contains(id) }

    /// Removes a model's files and reports the outcome, so the picker's Delete
    /// button does not have to decide what a failure means.
    ///
    /// Leaving `LocalTranscriptionPreferences` pointing at a deleted model would
    /// leave the app claiming an on-device route it can no longer take, which is
    /// exactly the kind of false readiness the source card exists to prevent —
    /// ``delete(_:)`` already clears it.
    func deleteReportingResult(_ descriptor: LocalModelDescriptor) {
        guard !isInert else { return }
        do {
            try delete(descriptor)
            failedIntegrityModelIDs.remove(descriptor.id)
            verifyingModelIDs.remove(descriptor.id)
            message = "\(descriptor.displayName) was removed from this iPhone."
            hasError = false
        } catch {
            message = "\(descriptor.displayName) could not be removed."
            hasError = true
        }
    }

    /// Loads the selected engine before the user starts dictating. The first
    /// Core ML or ONNX initialization can take a while, so this state is
    /// published for the picker instead of leaving the Use button appearing to
    /// do nothing.
    func prepare(_ descriptor: LocalModelDescriptor, language: String) async throws {
        guard let folder = modelDirectory(for: descriptor.id), isDownloaded(descriptor.id) else {
            throw LocalModelManagerError.modelNotDownloaded(descriptor.id)
        }
        // Loading Whisper/Sherpa in the background is a memory spike with no
        // user in front of the picker. The files stay on disk; the next
        // foreground prepare loads them.
        guard KeyboardPreferences.containingAppIsForeground else { return }

        loadingModelID = descriptor.id
        loadingMessage = "Loading \(descriptor.displayName)… This can take a moment."
        defer {
            loadingModelID = nil
            loadingMessage = nil
        }
        // Give SwiftUI a turn to render the loading state before synchronous
        // Sherpa initialization or the first Core ML load begins.
        await Task.yield()

        switch descriptor.engine {
        case .whisperKit:
            guard let tokenizerRepository = descriptor.tokenizerRepository,
                  let tokenizerFolder = tokenizerDirectory(for: tokenizerRepository)
            else { throw LocalModelManagerError.modelNotDownloaded(descriptor.id) }
            try LocalModelIntegrity.verifySizes(
                in: folder, files: LocalModelIntegrity.files(for: descriptor.id)
            )
            try LocalModelIntegrity.verifySizes(
                in: tokenizerFolder,
                files: LocalModelIntegrity.tokenizer(for: tokenizerRepository).files
            )
            _ = try await ensureWhisperKit(
                descriptor: descriptor,
                folder: folder,
                tokenizerFolder: tokenizerFolder
            )
        case .sherpaOnnx:
            let resolvedLanguage = descriptor.englishOnly ? "en" : language
            _ = try await ensureSherpaRecognizer(
                descriptor: descriptor,
                folder: folder,
                resolvedLanguage: resolvedLanguage
            )
        }
    }

    /// Rebuilds the engine after an accuracy change — and only when there is
    /// already one loaded to rebuild.
    ///
    /// Accuracy is read at inference time, so a model that is not currently in
    /// memory needs nothing done to it: the next dictation builds it with the
    /// new setting. Calling `prepare` unconditionally meant a Settings control
    /// pulling a whole speech-to-text model into memory — several hundred
    /// megabytes, with Core ML prewarm on top — which is the most expensive
    /// thing this app can do and the last thing a settings screen should be
    /// doing.
    ///
    /// Whisper is excluded even when it *is* loaded: WhisperKit takes its
    /// decoding options per call, so quality never invalidates it and the
    /// rebuild would be pure cost. Only sherpa bakes the decoding method into
    /// the recognizer.
    func reloadForAccuracyChange(language: String) async throws {
        guard let id = loadedModelID,
              sherpaRecognizer != nil,
              let descriptor = LocalModelCatalog.descriptor(for: id),
              descriptor.engine == .sherpaOnnx
        else { return }
        try await prepare(descriptor, language: language)
    }

    /// Prepares a Sherpa recognizer and starts consuming the lossless local
    /// capture queue immediately. WhisperKit keeps its finish-time path because
    /// its native decoder has a separate VAD/chunking implementation.
    func startSherpaIncrementalSession(
        chunks: AsyncStream<Data>,
        language: String
    ) async throws -> SherpaIncrementalSession? {
        guard let id = LocalTranscriptionPreferences.modelIdentifier,
              let descriptor = LocalModelCatalog.descriptor(for: id),
              descriptor.engine == .sherpaOnnx
        else { return nil }
        // Streaming decodes ten-second windows and stitches them by matching
        // repeated words across a half-second overlap. Both halves of that
        // assume the model returns the same words for the same audio, which a
        // translator does not: the overlap comes back reworded, so nothing is
        // deduplicated and the seam is duplicated instead — and a sentence
        // split across two windows is translated twice, as two fragments that
        // were never sentences. A translated dictation gives up the latency and
        // takes the whole-file path, where anything under twelve seconds is a
        // single decode of the whole thing.
        guard descriptor.resolvedTranslationTarget.isEmpty else { return nil }
        guard let folder = modelDirectory(for: id), isDownloaded(id) else {
            throw LocalModelManagerError.modelNotDownloaded(id)
        }

        let resolvedLanguage = descriptor.englishOnly ? "en" : language
        let recognizer = try await ensureSherpaRecognizer(
            descriptor: descriptor,
            folder: folder,
            resolvedLanguage: resolvedLanguage
        )
        return SherpaIncrementalSession(chunks: chunks, recognizer: recognizer)
    }

    func download(_ descriptor: LocalModelDescriptor) async throws {
        guard !isInert else { return }
        let id = descriptor.id
        inFlightDownloads[id] = InFlightDownload(
            fraction: 0,
            totalBytes: descriptor.sizeBytes,
            startedAt: Date()
        )
        Self.rememberDownload(id)
        message = nil
        hasError = false
        defer {
            inFlightDownloads[id] = nil
            // Finished, failed or cancelled — all three are answers, and none
            // of them should be retried on the next launch. Only a process
            // that never got here leaves the entry behind.
            Self.forgetDownload(id)
#if DEBUG
            ModelDownloadTrace.record("model.forget", id)
#endif
        }

        do {
            let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_000_000_000)
            guard ramGB >= descriptor.minimumRamGB else {
                throw LocalModelManagerError.insufficientMemory(requiredGB: descriptor.minimumRamGB)
            }
            guard let modelsDirectory, let tokenizersDirectory else {
                throw LocalModelManagerError.noModelContainer
            }
            // Checked here rather than only in the picker: a download reaching
            // 95% and then failing on a full iPhone is minutes of the user's
            // time and an error that does not say what to delete.
            let free = DownloadReadiness.availableStorageBytes(at: modelsDirectory)
            let needed = DownloadReadiness.requiredStorageBytes(descriptor.sizeBytes)
            if free > 0, free < needed {
                throw LocalModelManagerError.insufficientStorage(
                    freeBytes: free,
                    requiredBytes: needed
                )
            }
            try FileManager.default.createDirectory(
                at: modelsDirectory, withIntermediateDirectories: true
            )
            let folder: URL
            let progressTracker: DownloadProgress
            switch descriptor.engine {
            case .whisperKit:
                guard let tokenizerRepository = descriptor.tokenizerRepository else {
                    throw LocalModelManagerError.tokenizerManifestMissing(descriptor.id)
                }
                let tokenizer = try LocalModelIntegrity.tokenizer(for: tokenizerRepository)
                let modelFiles = try LocalModelIntegrity.files(for: descriptor.id)
                progressTracker = DownloadProgress(
                    totalBytes: tokenizer.files.reduce(Int64(0)) { $0 + $1.size }
                        + modelFiles.reduce(Int64(0)) { $0 + $1.size }
                )
                setTotalBytes(progressTracker.totalBytes, for: id)
                try FileManager.default.createDirectory(
                    at: tokenizersDirectory, withIntermediateDirectories: true
                )
                // The tokenizer comes first and is small: without it on disk,
                // WhisperKit reaches out to the network the first time the model
                // loads, which is exactly what on-device mode must never do.
                try await downloadTokenizer(
                    for: descriptor,
                    repository: tokenizerRepository,
                    into: tokenizersDirectory,
                    progressTracker: progressTracker
                )
                guard let repository = LocalModelIntegrity.repository,
                      let revision = LocalModelIntegrity.revision
                else {
                    throw LocalModelManagerError.integrityManifestMissing(descriptor.id)
                }
                folder = try await downloadModel(
                    descriptor,
                    into: modelsDirectory,
                    repository: repository,
                    revision: revision,
                    files: modelFiles,
                    pathPrefix: descriptor.id,
                    progressTracker: progressTracker
                )
            case .sherpaOnnx:
                let manifest = try LocalModelIntegrity.sherpaModel(for: descriptor.id)
                progressTracker = DownloadProgress(
                    totalBytes: manifest.files.reduce(Int64(0)) { $0 + $1.size }
                )
                setTotalBytes(progressTracker.totalBytes, for: id)
                folder = try await downloadModel(
                    descriptor,
                    into: modelsDirectory,
                    repository: manifest.repository,
                    revision: manifest.revision,
                    files: manifest.files,
                    pathPrefix: nil,
                    progressTracker: progressTracker
                )
            }
            downloadedModelIDs.insert(descriptor.id)
            persistPath(folder, for: descriptor.id)
            message = "\(descriptor.displayName) downloaded and verified."
            Telemetry.shared.modelDownloadFinished(model: descriptor, outcome: .completed)
        } catch is CancellationError {
            hasError = false
            message = nil
            Telemetry.shared.modelDownloadFinished(model: descriptor, outcome: .cancelled)
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            hasError = false
            message = nil
            Telemetry.shared.modelDownloadFinished(model: descriptor, outcome: .cancelled)
            throw CancellationError()
        } catch {
            hasError = true
            message = error.localizedDescription
            // The error itself is never passed on: its message can name a
            // download URL or a path inside the container, and the whole point
            // of the enum is that neither can get out.
            Telemetry.shared.modelDownloadFinished(
                model: descriptor,
                outcome: Self.downloadOutcome(for: error)
            )
            throw error
        }
    }

    /// Starts a model download whose lifetime is independent of the SwiftUI
    /// view that initiated it. Both onboarding and Settings use this entry
    /// point, so navigating, backgrounding, or a view refresh cannot detach the
    /// Cancel button from the active operation.
    func startDownload(
        _ descriptor: LocalModelDescriptor,
        onCompletion: @escaping @MainActor () -> Void = {}
    ) {
        guard !isInert else { return }
        switch ModelDownloadStartDecision.decide(
            downloadingIDs: downloadingModelIDs.union(Set(modelDownloadTasks.keys)),
            queuedIDs: Set(queuedModelIDs),
            requestedID: descriptor.id
        ) {
        case .alreadyThisModel, .alreadyQueued:
            return
        case .atCapacity:
            queuedDownloads.append((descriptor, onCompletion))
            queuedModelIDs.append(descriptor.id)
            return
        case .allowed:
            break
        }
        beginDownload(descriptor, onCompletion: onCompletion)
    }

    private func beginDownload(
        _ descriptor: LocalModelDescriptor,
        onCompletion: @escaping @MainActor () -> Void
    ) {
        let id = descriptor.id
        modelDownloadTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.modelDownloadTasks[id] = nil
                onCompletion()
                self.startNextQueuedDownload()
            }
            do {
#if DEBUG
                ModelDownloadTrace.record("model.begin", id)
#endif
                try await self.download(descriptor)
#if DEBUG
                ModelDownloadTrace.record("model.ok", id)
#endif
            } catch {
#if DEBUG
                ModelDownloadTrace.record("model.fail", "\(id) \(error)")
#endif
                // `download` publishes either the actionable error or the
                // normal cancellation message used by both picker surfaces.
            }
        }
    }

    private func startNextQueuedDownload() {
        while let next = queuedDownloads.first {
            let id = next.descriptor.id
            switch ModelDownloadStartDecision.decide(
                downloadingIDs: downloadingModelIDs.union(Set(modelDownloadTasks.keys)),
                requestedID: id
            ) {
            case .alreadyThisModel:
                queuedDownloads.removeFirst()
                queuedModelIDs.removeAll { $0 == id }
            case .atCapacity, .alreadyQueued:
                return
            case .allowed:
                queuedDownloads.removeFirst()
                queuedModelIDs.removeAll { $0 == id }
                if isDownloaded(id), !failedIntegrityModelIDs.contains(id) {
                    next.onCompletion()
                    continue
                }
                beginDownload(next.descriptor, onCompletion: next.onCompletion)
                return
            }
        }
    }

    func cancelDownload(_ id: String? = nil) {
        if let id {
            if let index = queuedDownloads.firstIndex(where: { $0.descriptor.id == id }) {
                queuedDownloads.remove(at: index)
                queuedModelIDs.removeAll { $0 == id }
                return
            }
            guard modelDownloadTasks[id] != nil || inFlightDownloads[id] != nil else { return }
            inFlightDownloads[id] = nil
            modelDownloadTasks[id]?.cancel()
            return
        }
        guard !modelDownloadTasks.isEmpty || !inFlightDownloads.isEmpty || !queuedDownloads.isEmpty
        else { return }
        inFlightDownloads.removeAll()
        queuedDownloads.removeAll()
        queuedModelIDs.removeAll()
        modelDownloadTasks.values.forEach { $0.cancel() }
    }

    /// A failed download that failed its integrity check is worth telling apart
    /// from one that simply could not finish: the first means a pinned digest no
    /// longer matches what the host serves, which is a supply-chain signal
    /// rather than a flaky network.
    static func downloadOutcome(for error: Error) -> TelemetryDownloadOutcome {
        switch error {
        case LocalModelManagerError.integrityFileMissing,
            LocalModelManagerError.integrityManifestMissing:
            .integrityFailed
        default:
            .failed
        }
    }

    private func downloadTokenizer(
        for descriptor: LocalModelDescriptor,
        repository: String,
        into root: URL,
        progressTracker: DownloadProgress
    ) async throws {
        let tokenizer = try LocalModelIntegrity.tokenizer(for: repository)
        let destination = root.appendingPathComponent(
            Self.tokenizerFolderName(for: repository), isDirectory: true
        )
        let fingerprint = LocalModelIntegrity.fingerprint(of: tokenizer.files)
        if Self.tokenizerIsInstalled(fingerprint, at: destination, files: tokenizer.files) {
            reportProgress(
                await progressTracker.addCompleted(
                    tokenizer.files.reduce(Int64(0)) { $0 + $1.size }
                ),
                for: descriptor.id
            )
            return
        }

        message = "Downloading the \(descriptor.displayName) tokenizer…"
        let staging = root.appendingPathComponent(
            ".tokenizer-\(UUID().uuidString)", isDirectory: true
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { Self.removeItemLater(staging) }

        for file in tokenizer.files {
            try Task.checkCancellation()
            guard isSafeRelativePath(file.path) else {
                throw LocalModelManagerError.integrityFileMissing(file.path)
            }
            let url = try fileURL(
                repository: repository, revision: tokenizer.revision, path: file.path
            )
            try await downloadFile(
                from: url,
                to: staging.appendingPathComponent(file.path),
                expectedBytes: file.size,
                progressTracker: progressTracker,
                modelID: descriptor.id
            )
        }
        try await Self.verifyDigests(
            in: staging, files: tokenizer.files, modelIdentifier: repository
        )
        // A tokenizer repository is shared: four models fetch
        // `openai/whisper-large-v3`, and two downloads now run at once. The
        // copy that arrives second must neither delete a good install out from
        // under the first, nor fail because the destination appeared while
        // this one was still downloading. Identical content either way.
        if Self.tokenizerIsInstalled(fingerprint, at: destination, files: tokenizer.files) {
            return
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            guard Self.tokenizerIsInstalled(
                fingerprint, at: destination, files: tokenizer.files
            ) else { throw error }
        }
    }

    /// The tokenizer this fingerprint describes is already on disk, whole.
    private static func tokenizerIsInstalled(
        _ fingerprint: String,
        at destination: URL,
        files: [LocalModelIntegrity.ManifestFile]
    ) -> Bool {
        (try? LocalModelIntegrity.verifySizes(in: destination, files: files)) != nil
            && LocalModelIntegrity.markerMatches(fingerprint, in: destination)
    }

    private func downloadModel(
        _ descriptor: LocalModelDescriptor,
        into root: URL,
        repository: String,
        revision: String,
        files: [LocalModelIntegrity.ManifestFile],
        pathPrefix: String?,
        progressTracker: DownloadProgress
    ) async throws -> URL {
        let stagingRoot = root.appendingPathComponent(
            ".download-\(descriptor.id)-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingModel = stagingRoot.appendingPathComponent(descriptor.id, isDirectory: true)
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: stagingModel, withIntermediateDirectories: true)
        defer { Self.removeItemLater(stagingRoot) }

        for file in files where !isSafeRelativePath(file.path) {
            throw LocalModelManagerError.integrityFileMissing(file.path)
        }

        message = "Downloading \(descriptor.displayName)…"

        // Every model in the catalog is one to three very large weights beside a
        // dozen or more tiny descriptors. Fetching the small ones several at a
        // time stops each of them paying a fresh TLS handshake and a Hugging
        // Face redirect in turn, which is most of what they cost. The large ones
        // stay sequential: splitting a single stream into parallel byte ranges
        // measured no reliable gain and sometimes lost, which does not justify
        // the reassembly pass or giving up resume on a retry.
        let large = files.filter { $0.size >= Self.largeFileThreshold }
        let small = files.filter { $0.size < Self.largeFileThreshold }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = small.makeIterator()
            var inFlight = 0
            while inFlight < Self.maxParallelTransfers, let file = pending.next() {
                group.addTask {
                    try await self.downloadAndVerify(
                        file,
                        modelIdentifier: descriptor.id,
                        repository: repository,
                        revision: revision,
                        pathPrefix: pathPrefix,
                        into: stagingModel,
                        progressTracker: progressTracker
                    )
                }
                inFlight += 1
            }
            while inFlight > 0 {
                try await group.next()
                inFlight -= 1
                guard let file = pending.next() else { continue }
                group.addTask {
                    try await self.downloadAndVerify(
                        file,
                        modelIdentifier: descriptor.id,
                        repository: repository,
                        revision: revision,
                        pathPrefix: pathPrefix,
                        into: stagingModel,
                        progressTracker: progressTracker
                    )
                }
                inFlight += 1
            }
        }

        for file in large {
            try Task.checkCancellation()
            try await downloadAndVerify(
                file,
                modelIdentifier: descriptor.id,
                repository: repository,
                revision: revision,
                pathPrefix: pathPrefix,
                into: stagingModel,
                progressTracker: progressTracker
            )
        }

        // Every file was hashed as it landed, so all that is left is confirming
        // the set is complete and recording the marker the cheap launch path
        // reads. The whole-directory digest pass that used to run here hashed
        // every byte of the model a second time, on the main actor.
        try LocalModelIntegrity.verifySizes(
            in: stagingModel, files: files, requiringMarker: false
        )
        try LocalModelIntegrity.writeMarker(
            LocalModelIntegrity.fingerprint(of: files), in: stagingModel
        )

        let finalFolder = root.appendingPathComponent(descriptor.id, isDirectory: true)
        if fileManager.fileExists(atPath: finalFolder.path) {
            try fileManager.removeItem(at: finalFolder)
        }
        try fileManager.moveItem(at: stagingModel, to: finalFolder)
        return finalFolder
    }

    /// Fetches one manifest file into the staging folder and checks its digest
    /// before committing it under its real name.
    private func downloadAndVerify(
        _ file: LocalModelIntegrity.ManifestFile,
        modelIdentifier: String,
        repository: String,
        revision: String,
        pathPrefix: String?,
        into stagingModel: URL,
        progressTracker: DownloadProgress
    ) async throws {
        let url = try fileURL(
            repository: repository,
            revision: revision,
            path: [pathPrefix, file.path].compactMap { $0 }.joined(separator: "/")
        )
        let destination = stagingModel.appendingPathComponent(file.path)
        let temporaryFile = try await downloadFile(
            from: url,
            to: destination,
            keepingPartialExtension: true,
            expectedBytes: file.size,
            progressTracker: progressTracker,
            modelID: modelIdentifier
        )
        try await Self.verify(
            file: temporaryFile, against: file, modelIdentifier: modelIdentifier
        )
        try FileManager.default.moveItem(at: temporaryFile, to: destination)
    }

    /// Digest work is CPU-bound file I/O over hundreds of megabytes. On the main
    /// actor it froze the picker at the end of a large download, which reads as
    /// a stalled progress bar rather than as verification.
    private nonisolated static func verify(
        file url: URL,
        against expectedFile: LocalModelIntegrity.ManifestFile,
        modelIdentifier: String?
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try LocalModelIntegrity.verify(
                file: url, against: expectedFile, modelIdentifier: modelIdentifier
            )
        }.value
    }

    private nonisolated static func verifyDigests(
        in directory: URL,
        files: [LocalModelIntegrity.ManifestFile],
        modelIdentifier: String?
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try LocalModelIntegrity.verifyDigests(
                in: directory, files: files, modelIdentifier: modelIdentifier
            )
        }.value
    }

    /// Downloads one file into place, creating intermediate directories. When
    /// `keepingPartialExtension` is set the caller verifies the `.partial` file
    /// before committing it.
    @discardableResult
    private func downloadFile(
        from url: URL,
        to destination: URL,
        keepingPartialExtension: Bool = false,
        expectedBytes: Int64,
        progressTracker: DownloadProgress,
        modelID: String
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let target = keepingPartialExtension
            ? destination.appendingPathExtension("partial")
            : destination
        try? fileManager.removeItem(at: target)

        let file = try await downloadUnit(
            from: url,
            expectedBytes: expectedBytes,
            progressTracker: progressTracker,
            modelID: modelID
        )
        try fileManager.moveItem(at: file, to: target)
        return target
    }

    /// One file transfer with its own retry budget. Returns a temporary file
    /// the caller owns.
    private func downloadUnit(
        from url: URL,
        expectedBytes: Int64,
        progressTracker: DownloadProgress,
        modelID: String
    ) async throws -> URL {
        let fileManager = FileManager.default
        let unit = UUID()
        await progressTracker.begin(unit)

        // `<model id>:<path in the repo>` — the whole path, not the file name.
        //
        // A Core ML model is a set of `.mlmodelc` bundles that all use the same
        // names inside: every one has a `weights/weight.bin`, a `coremldata.bin`
        // and a `model.mil`. Keyed on the last path component, a resumed
        // download asked for the audio encoder's `weight.bin` and was handed
        // the text decoder's — by the inbox claim, and by the inheritance map,
        // where one live task silently replaced another under the same key.
        // The wrong weights landed in the encoder's place and the integrity
        // check failed on their size.
        //
        // The path is stable across requests because this is the repository
        // URL, before the redirect; the signed CDN address with its `Expires`
        // and `Signature` only exists inside URLSession after it.
        let key = "\(modelID):\(url.path)"
        if let claimed = Self.downloadDelegate.claimFinishedFile(
            key: key,
            expectedBytes: expectedBytes
        ) {
            reportProgress(
                await progressTracker.complete(unit, bytes: expectedBytes),
                for: modelID
            )
            return claimed
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15 * 60

        let progressHandler: @Sendable (Int64) -> Void = { [weak self] bytesWritten in
            Task { @MainActor [weak self] in
                guard let value = await progressTracker.update(
                    unit, bytesWritten: bytesWritten, expectedBytes: expectedBytes
                ) else { return }
                self?.reportProgress(value, for: modelID)
            }
        }

        let session = KeyboardPreferences.containingAppIsForeground
            ? Self.foregroundDownloadSession
            : Self.backgroundDownloadSession
        let maxAttempts = 3
        var resumeData: Data?
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                let (temporaryFile, response) = try await Self.downloadDelegate.start(
                    session: session,
                    request: request,
                    expectedBytes: expectedBytes,
                    resumeData: resumeData,
                    key: key,
                    progressHandler: progressHandler
                )
                try Task.checkCancellation()
                guard let httpResponse = response as? HTTPURLResponse,
                      200..<300 ~= httpResponse.statusCode
                else {
                    try? fileManager.removeItem(at: temporaryFile)
                    throw LocalModelManagerError.downloadFailed(
                        path: url.lastPathComponent,
                        statusCode: (response as? HTTPURLResponse)?.statusCode
                    )
                }
                reportProgress(
                    await progressTracker.complete(unit, bytes: expectedBytes),
                    for: modelID
                )
                return temporaryFile
            } catch {
                reportProgress(await progressTracker.reset(unit), for: modelID)
                guard attempt < maxAttempts, isRetryableDownloadError(error) else {
                    _ = await progressTracker.complete(unit, bytes: 0)
                    throw error
                }
                // A dropped connection at 90% of a 1.27 GB weight used to cost
                // the whole file. Resume data picks it up where it stopped.
                resumeData = (error as NSError)
                    .userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                message = "Network interruption. Retrying \(url.lastPathComponent)…"
                try await Task.sleep(nanoseconds: UInt64(attempt) * 750_000_000)
            }
        }

        _ = await progressTracker.complete(unit, bytes: 0)
        throw LocalModelManagerError.downloadFailed(
            path: url.lastPathComponent,
            statusCode: nil
        )
    }

    /// Several transfers report at once and their main-actor hops can land out
    /// of order, which must not make the bar jump backwards mid-download.
    private func reportProgress(_ value: Double, for id: String) {
        guard var item = inFlightDownloads[id] else { return }
        guard value >= item.fraction else { return }
        item.fraction = value
        inFlightDownloads[id] = item
    }

    private func setTotalBytes(_ bytes: Int64, for id: String) {
        guard var item = inFlightDownloads[id] else { return }
        item.totalBytes = bytes
        inFlightDownloads[id] = item
    }

    /// Staging folders can be hundreds of megabytes. Deleting them on the
    /// main actor is what made Stop hitch after a Get.
    private static func removeItemLater(_ url: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func isRetryableDownloadError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? URLError {
            return [
                .timedOut,
                .networkConnectionLost,
                .notConnectedToInternet,
                .cannotFindHost,
                .cannotConnectToHost,
                .dnsLookupFailed,
                .resourceUnavailable
            ].contains(error.code)
        }
        if case let LocalModelManagerError.downloadFailed(_, statusCode) = error {
            return [408, 425, 429, 500, 502, 503, 504].contains(statusCode)
        }
        return false
    }

    private func fileURL(
        repository: String,
        revision: String,
        path: String
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(path)"
        components.queryItems = [URLQueryItem(name: "download", value: "true")]
        guard let url = components.url else {
            throw LocalModelManagerError.downloadFailed(path: path, statusCode: nil)
        }
        return url
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return !components.isEmpty
            && components.allSatisfy { component in
                component != "." && component != ".."
            }
    }

    /// Drops the loaded engine and its weights.
    ///
    /// The model is kept after a dictation so the next one starts instantly,
    /// which is right for the next dictation and wrong for the ten minutes of
    /// standby that usually follow it: several hundred megabytes resident for
    /// nothing. iOS answers memory pressure by shrinking what it allows an app
    /// *extension*, so the process that pays is the keyboard — launched with
    /// four megabytes of headroom, killed at once, and the user is handed
    /// somebody else's keyboard mid-sentence.
    ///
    /// The caller decides when: see `RecordingCoordinator`, which waits for the
    /// window to go quiet and answers memory warnings with this.
    @discardableResult
    func releaseLoadedEngines() -> Bool {
        guard whisperKit != nil || sherpaRecognizer != nil else { return false }
        whisperKit = nil
        sherpaRecognizer = nil
        loadedModelID = nil
        loadedLanguage = nil
        loadedTranslateTo = ""
        loadedQuality = nil
        return true
    }

    func delete(_ descriptor: LocalModelDescriptor) throws {
        guard let folder = modelDirectory(for: descriptor.id) else {
            throw LocalModelManagerError.noModelContainer
        }
        if loadedModelID == descriptor.id {
            whisperKit = nil
            sherpaRecognizer = nil
            loadedModelID = nil
            loadedLanguage = nil
            loadedQuality = nil
        }
        try? FileManager.default.removeItem(at: folder)
        downloadedModelIDs.remove(descriptor.id)
        removePersistedPath(for: descriptor.id)
        // The tokenizer is a few megabytes and is shared with the other sizes of
        // the same variant, so it stays behind.
        if LocalTranscriptionPreferences.modelIdentifier == descriptor.id {
            LocalTranscriptionPreferences.modelIdentifier = nil
            LocalTranscriptionPreferences.enabled = false
        }
    }

    /// What an on-device engine produced, and the language that governs its output.
    ///
    /// The language matters because the writing styles punctuate by script — a
    /// Devanagari sentence ends in a danda, not a full stop — and with Automatic
    /// selected the request says only "auto". WhisperKit detects and reports;
    /// the sherpa bridge does not expose it, so it leaves this empty and the
    /// styler falls back to inspecting the text. An explicit selection stays
    /// authoritative even if an engine reports something contradictory.
    struct LocalTranscription: Sendable {
        let text: String
        let language: String
    }

    func transcribe(audioURL: URL, language: String) async throws -> LocalTranscription {
        guard let id = LocalTranscriptionPreferences.modelIdentifier,
              let descriptor = LocalModelCatalog.descriptor(for: id)
        else { throw LocalModelManagerError.modelNotDownloaded("none") }
        guard let folder = modelDirectory(for: id), isDownloaded(id)
        else { throw LocalModelManagerError.modelNotDownloaded(id) }

        let resolvedLanguage = descriptor.englishOnly ? "en" : language
        let needsLoad: Bool
        switch descriptor.engine {
        case .whisperKit:
            needsLoad = loadedModelID != id || whisperKit == nil
        case .sherpaOnnx:
            // A language change only means a rebuild for the families whose
            // config carries one. Rebuilding a 670 MB Parakeet because the user
            // relabelled the transcript language would cost seconds and change
            // nothing about the decode.
            let languageIsBakedIn = descriptor.sherpaFamily?.acceptsLanguage ?? true
            let identityChanged = loadedLanguage != resolvedLanguage
                || loadedTranslateTo != descriptor.resolvedTranslationTarget
            needsLoad = loadedModelID != id
                || (languageIsBakedIn && identityChanged)
                || loadedQuality != LocalTranscriptionPreferences.quality
                || sherpaRecognizer == nil
        }
        if needsLoad {
            loadingModelID = id
            loadingMessage = "Loading \(descriptor.displayName)… This can take a moment."
        }
        defer {
            if needsLoad {
                loadingModelID = nil
                loadingMessage = nil
            }
        }
        if needsLoad { await Task.yield() }

        let loaded = try Self.loadSamples(from: audioURL)
        guard !loaded.isEmpty else { throw LocalModelManagerError.modelNotDownloaded("empty audio") }
        // Safe here and not on the incremental path: this is the whole recording,
        // so one gain covers all of it.
        let samples = SpeechAudioConditioning.condition(loaded)

        switch descriptor.engine {
        case .whisperKit:
            guard let tokenizerRepository = descriptor.tokenizerRepository,
                  let tokenizerFolder = tokenizerDirectory(for: tokenizerRepository)
            else { throw LocalModelManagerError.modelNotDownloaded(id) }

            try LocalModelIntegrity.verifySizes(
                in: folder, files: LocalModelIntegrity.files(for: id)
            )
            try LocalModelIntegrity.verifySizes(
                in: tokenizerFolder,
                files: LocalModelIntegrity.tokenizer(for: tokenizerRepository).files
            )
            let whisperKit = try await ensureWhisperKit(
                descriptor: descriptor,
                folder: folder,
                tokenizerFolder: tokenizerFolder
            )
            let requested = resolvedLanguage == "auto" ? nil : resolvedLanguage
            let quality = LocalTranscriptionPreferences.quality
            // Tokenized here rather than stored, because the tokens only mean
            // anything against the tokenizer of the model that is loaded.
            let promptText = CustomVocabulary.whisperPrompt(
                LocalTranscriptionPreferences.customVocabulary
            )
            let promptTokens = promptText.isEmpty
                ? nil
                : whisperKit.tokenizer?.encode(text: promptText)
            // Whisper's translate task has exactly one trained target, English,
            // and `translationTarget` can only ever be "en" for a Whisper
            // model. Asking it for another target is not a smaller version of
            // the same feature; it is nothing at all.
            let translateTo = descriptor.resolvedTranslationTarget
            let options = DecodingOptions(
                task: translateTo.isEmpty ? .transcribe : .translate,
                language: requested,
                temperature: 0,
                temperatureIncrementOnFallback: quality.whisperKitTemperatureIncrement,
                temperatureFallbackCount: quality.whisperKitTemperatureFallbackCount,
                usePrefillPrompt: true,
                usePrefillCache: true,
                // WhisperKit derives this from `usePrefillPrompt`, so leaving it
                // unset with prefill on resolves it to false — and a nil language
                // then falls back to English rather than being detected. Automatic
                // has to ask for detection in so many words.
                detectLanguage: requested == nil,
                skipSpecialTokens: true,
                // Timestamp tokens are not shown, but Whisper needs to predict
                // them to stop cleanly instead of repeating into padded audio.
                withoutTimestamps: false,
                promptTokens: promptTokens,
                // WhisperKit defaults this off where Whisper itself defaults it
                // on. Leaving it off lets a window open on a blank token, which
                // is how a pause becomes a leading empty segment.
                suppressBlank: true,
                chunkingStrategy: .vad
            )
            let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw LocalModelManagerError.emptyTranscript
            }
            // Detection is meaningful only for Automatic. With an explicit
            // selection, the user's requested output language remains the
            // contract even if the engine reports something contradictory.
            // Translating overrides both: the detected language is the one that
            // was spoken, and the text on screen is the target.
            return LocalTranscription(
                text: text,
                language: ModelLanguageSupport.outputLanguage(
                    requested: resolvedLanguage,
                    reported: results.first?.language ?? "",
                    translateTo: translateTo
                )
            )

        case .sherpaOnnx:
            let sherpaRecognizer = try await ensureSherpaRecognizer(
                descriptor: descriptor,
                folder: folder,
                resolvedLanguage: resolvedLanguage
            )
            let outcome = await Task.detached(priority: .userInitiated) {
                sherpaRecognizer.transcribe(samples)
            }.value
            // Told apart deliberately. A recognizer that would not open a stream
            // and a model that heard no speech both arrive here with no text,
            // and reporting them as one thing is what made a device report
            // unable to say whether the empty-result repair is working.
            if let failure = outcome.nativeFailure {
                throw LocalModelManagerError.engineDecodeFailed(failure.rawValue)
            }
            let decoded = outcome.transcriptOrEmpty
            guard !decoded.text.isEmpty else {
                throw LocalModelManagerError.emptyTranscript
            }
            return LocalTranscription(
                text: decoded.text,
                language: ModelLanguageSupport.outputLanguage(
                    requested: resolvedLanguage,
                    reported: decoded.language,
                    translateTo: descriptor.resolvedTranslationTarget
                )
            )
        }
    }

    private func ensureWhisperKit(
        descriptor: LocalModelDescriptor,
        folder: URL,
        tokenizerFolder: URL
    ) async throws -> WhisperKit {
        if loadedModelID != descriptor.id || whisperKit == nil {
            // Both engines released before the new one is built, for the same
            // reason as in `ensureSherpaRecognizer`: two sets of model weights
            // resident at once is an out-of-memory kill on a phone, and the
            // previous Whisper model is exactly that much memory.
            sherpaRecognizer = nil
            whisperKit = nil
            loadedModelID = nil
            loadedLanguage = nil
            loadedQuality = nil
            whisperKit = try await WhisperKit(
                WhisperKitConfig(
                    model: descriptor.id,
                    modelFolder: folder.path,
                    // WhisperKit searches this folder directly for tokenizer.json;
                    // supplying it is what keeps model loading off the network.
                    tokenizerFolder: tokenizerFolder,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: false
                )
            )
            loadedModelID = descriptor.id
            loadedLanguage = nil
        }
        guard let whisperKit else {
            throw LocalModelManagerError.modelNotDownloaded(descriptor.id)
        }
        return whisperKit
    }

    private func ensureSherpaRecognizer(
        descriptor: LocalModelDescriptor,
        folder: URL,
        resolvedLanguage: String
    ) async throws -> SherpaRecognizer {
        let files = try LocalModelIntegrity.sherpaModel(for: descriptor.id).files
        try LocalModelIntegrity.verifySizes(in: folder, files: files)
        // Sherpa bakes the decoding method into the recognizer, so a change of
        // quality means building a new one — but only where the two fields it
        // reaches actually differ. Every bundled family is on greedy search
        // today, so this normalises to one value and the accuracy control stops
        // rebuilding a large model to produce an identical one.
        let quality = descriptor.sherpaFamily?
            .effectiveQuality(LocalTranscriptionPreferences.quality)
            ?? LocalTranscriptionPreferences.quality
        // Resolved from the catalog rather than trusted from a caller, so a
        // target picked under Canary and still stored after a switch to
        // Parakeet can never reach an engine that would misread it.
        let translateTo = descriptor.resolvedTranslationTarget

        // Never two loads at once. Building an ONNX graph while another is
        // still being built puts both models' weights in memory at the same
        // time, which on a phone is an out-of-memory kill rather than a slow
        // moment. Changing the accuracy setting twice in quick succession is
        // exactly how that used to happen.
        while let inFlight = sherpaLoad {
            _ = try? await inFlight.value
            if sherpaLoad == inFlight { sherpaLoad = nil }
        }

        if let sherpaRecognizer,
           loadedModelID == descriptor.id,
           descriptor.sherpaFamily?.acceptsLanguage != true
               || (loadedLanguage == resolvedLanguage && loadedTranslateTo == translateTo),
           loadedQuality == quality
        {
            return sherpaRecognizer
        }

        // Released *before* the replacement is built, not after. Holding the
        // old recognizer across the load doubles peak memory for the duration —
        // and for a several-hundred-megabyte model that is the difference
        // between a pause and the app being killed. The cost of getting this
        // wrong in the other direction is one failed load that the next
        // dictation rebuilds, so this is the safe side to err on.
        whisperKit = nil
        sherpaRecognizer = nil
        loadedModelID = nil
        loadedLanguage = nil
        loadedTranslateTo = ""
        loadedQuality = nil

        // Off the main actor: `SherpaRecognizer.create` is synchronous and
        // reads hundreds of megabytes from disk, so running it here froze the
        // interface that had just published "Loading…".
        let threads = max(2, min(ProcessInfo.processInfo.processorCount - 2, 4))
        let task = Task.detached(priority: .userInitiated) {
            try SherpaRecognizer.create(
                model: descriptor,
                directory: folder,
                language: resolvedLanguage,
                // ONNX Runtime's CPU pool benefits from a bounded number of
                // workers on iPhone; using every logical core throttles long
                // recordings and competes with audio/UI work.
                threads: threads,
                quality: quality,
                translateTo: translateTo
            )
        }
        sherpaLoad = task
        defer { if sherpaLoad == task { sherpaLoad = nil } }

        let recognizer = try await task.value
        sherpaRecognizer = recognizer
        loadedModelID = descriptor.id
        loadedLanguage = resolvedLanguage
        loadedTranslateTo = translateTo
        loadedQuality = quality
        return recognizer
    }

    private func modelDirectory(for id: String) -> URL? {
        let defaults = [
            UserDefaults.standard,
            UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
        ].compactMap { $0 }
        for defaults in defaults {
            if let stored = defaults.string(forKey: pathKey(for: id)) {
                let url = URL(fileURLWithPath: stored)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        guard let root = modelsDirectory else { return nil }
        let url = root.appendingPathComponent(id, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func tokenizerDirectory(for repository: String) -> URL? {
        tokenizersDirectory?.appendingPathComponent(
            Self.tokenizerFolderName(for: repository), isDirectory: true
        )
    }

    private static func tokenizerFolderName(for repository: String) -> String {
        repository.replacingOccurrences(of: "/", with: "_")
    }

    private func persistPath(_ url: URL, for id: String) {
        UserDefaults.standard.set(url.path, forKey: pathKey(for: id))
        UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)?.set(
            url.path, forKey: pathKey(for: id)
        )
    }

    private func removePersistedPath(for id: String) {
        UserDefaults.standard.removeObject(forKey: pathKey(for: id))
        UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)?.removeObject(
            forKey: pathKey(for: id)
        )
    }

    private func pathKey(for id: String) -> String { "localModelPath.\(id)" }

    private static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return []
        }
        try file.read(into: buffer, frameCount: capacity)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}


#if DEBUG
/// Append-only record of a model download's life, readable off the device
/// with `devicectl ... --domain-type appDataContainer`. The failures worth
/// catching happen while the app is suspended or already dead, where nothing
/// on screen can reach.
enum ModelDownloadTrace {
    private static let lock = NSLock()

    static func record(_ event: String, _ detail: String = "") {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("model-download-trace.log")
        else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let pid = ProcessInfo.processInfo.processIdentifier
        let head = "\(stamp) pid=\(pid) \(event)"
        guard let data = (detail.isEmpty ? head + "\n" : head + " \(detail)\n").data(using: .utf8)
        else { return }
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
