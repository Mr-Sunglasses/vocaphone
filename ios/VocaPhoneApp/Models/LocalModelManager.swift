import AVFAudio
import Foundation
import Observation
@preconcurrency import WhisperKit

@MainActor
@Observable
final class LocalModelManager {
    private(set) var downloadedModelIDs: Set<String> = []
    private(set) var downloadingModelID: String?
    private(set) var progress: Double = 0
    private(set) var loadingModelID: String?
    private(set) var loadingMessage: String?
    private(set) var message: String?
    private(set) var hasError = false

    private var whisperKit: WhisperKit?
    private var sherpaRecognizer: SherpaRecognizer?
    private var loadedModelID: String?
    private var loadedLanguage: String?
    private let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration)
    }()

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
        refresh()
    }

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

    /// Tracks bytes across tokenizer and model files so the picker can show
    /// meaningful progress rather than waiting for a whole multi-hundred-MB
    /// file to finish.
    private final class DownloadProgress {
        let totalBytes: Int64
        var completedBytes: Int64 = 0

        init(totalBytes: Int64) {
            self.totalBytes = totalBytes
        }

        func add(_ bytes: Int64) -> Double {
            completedBytes += bytes
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(completedBytes) / Double(totalBytes))
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
            if verified {
                downloadedModelIDs.insert(identifier)
            } else {
                downloadedModelIDs.remove(identifier)
            }
        }
    }

    func isDownloaded(_ id: String) -> Bool { downloadedModelIDs.contains(id) }

    /// Loads the selected engine before the user starts dictating. The first
    /// Core ML or ONNX initialization can take a while, so this state is
    /// published for the picker instead of leaving the Use button appearing to
    /// do nothing.
    func prepare(_ descriptor: LocalModelDescriptor, language: String) async throws {
        guard let folder = modelDirectory(for: descriptor.id), isDownloaded(descriptor.id) else {
            throw LocalModelManagerError.modelNotDownloaded(descriptor.id)
        }

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
            _ = try ensureSherpaRecognizer(
                descriptor: descriptor,
                folder: folder,
                resolvedLanguage: resolvedLanguage
            )
        }
    }

    /// Prepares a Sherpa recognizer and starts consuming the lossless local
    /// capture queue immediately. WhisperKit keeps its finish-time path because
    /// its native decoder has a separate VAD/chunking implementation.
    func startSherpaIncrementalSession(
        chunks: AsyncStream<Data>,
        language: String
    ) throws -> SherpaIncrementalSession? {
        guard let id = LocalTranscriptionPreferences.modelIdentifier,
              let descriptor = LocalModelCatalog.descriptor(for: id),
              descriptor.engine == .sherpaOnnx
        else { return nil }
        guard let folder = modelDirectory(for: id), isDownloaded(id) else {
            throw LocalModelManagerError.modelNotDownloaded(id)
        }

        let resolvedLanguage = descriptor.englishOnly ? "en" : language
        let recognizer = try ensureSherpaRecognizer(
            descriptor: descriptor,
            folder: folder,
            resolvedLanguage: resolvedLanguage
        )
        return SherpaIncrementalSession(chunks: chunks, recognizer: recognizer)
    }

    func download(_ descriptor: LocalModelDescriptor) async throws {
        downloadingModelID = descriptor.id
        progress = 0
        message = nil
        hasError = false
        defer {
            downloadingModelID = nil
            progress = 0
        }

        do {
            let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_000_000_000)
            guard ramGB >= descriptor.minimumRamGB else {
                throw LocalModelManagerError.insufficientMemory(requiredGB: descriptor.minimumRamGB)
            }
            guard let modelsDirectory, let tokenizersDirectory else {
                throw LocalModelManagerError.noModelContainer
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
        } catch is CancellationError {
            hasError = false
            message = "Model download canceled."
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            hasError = false
            message = "Model download canceled."
            throw CancellationError()
        } catch {
            hasError = true
            message = error.localizedDescription
            throw error
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
        if (try? LocalModelIntegrity.verifySizes(in: destination, files: tokenizer.files)) != nil,
           LocalModelIntegrity.markerMatches(fingerprint, in: destination) {
            progress = progressTracker.add(tokenizer.files.reduce(Int64(0)) { $0 + $1.size })
            return
        }

        message = "Downloading the \(descriptor.displayName) tokenizer…"
        let staging = root.appendingPathComponent(
            ".tokenizer-\(UUID().uuidString)", isDirectory: true
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

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
                progressTracker: progressTracker
            )
        }
        try LocalModelIntegrity.verifyDigests(
            in: staging, files: tokenizer.files, modelIdentifier: repository
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
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
        defer { try? fileManager.removeItem(at: stagingRoot) }

        for file in files {
            try Task.checkCancellation()
            guard isSafeRelativePath(file.path) else {
                throw LocalModelManagerError.integrityFileMissing(file.path)
            }

            let destination = stagingModel.appendingPathComponent(file.path)
            message = "Downloading \(descriptor.displayName)…"
            let url = try fileURL(
                repository: repository,
                revision: revision,
                path: [pathPrefix, file.path].compactMap { $0 }.joined(separator: "/")
            )
            let temporaryFile = try await downloadFile(
                from: url,
                to: destination,
                keepingPartialExtension: true,
                progressTracker: progressTracker
            )
            try LocalModelIntegrity.verify(file: temporaryFile, against: file)
            try fileManager.moveItem(at: temporaryFile, to: destination)

        }

        try LocalModelIntegrity.verifyDigests(
            in: stagingModel, files: files, modelIdentifier: descriptor.id
        )
        let finalFolder = root.appendingPathComponent(descriptor.id, isDirectory: true)
        if fileManager.fileExists(atPath: finalFolder.path) {
            try fileManager.removeItem(at: finalFolder)
        }
        try fileManager.moveItem(at: stagingModel, to: finalFolder)
        return finalFolder
    }

    /// Downloads one file into place, creating intermediate directories. When
    /// `keepingPartialExtension` is set the caller verifies the `.partial` file
    /// before committing it.
    @discardableResult
    private func downloadFile(
        from url: URL,
        to destination: URL,
        keepingPartialExtension: Bool = false,
        progressTracker: DownloadProgress
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let target = keepingPartialExtension
            ? destination.appendingPathExtension("partial")
            : destination
        try? fileManager.removeItem(at: target)

        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        let (bytes, response) = try await downloadSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode
        else {
            throw LocalModelManagerError.downloadFailed(
                path: url.lastPathComponent,
                statusCode: (response as? HTTPURLResponse)?.statusCode
            )
        }
        fileManager.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                progress = progressTracker.add(Int64(buffer.count))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            progress = progressTracker.add(Int64(buffer.count))
        }
        return target
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

    func delete(_ descriptor: LocalModelDescriptor) throws {
        guard let folder = modelDirectory(for: descriptor.id) else {
            throw LocalModelManagerError.noModelContainer
        }
        if loadedModelID == descriptor.id {
            whisperKit = nil
            sherpaRecognizer = nil
            loadedModelID = nil
            loadedLanguage = nil
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

    func transcribe(audioURL: URL, language: String) async throws -> String {
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
            needsLoad = loadedModelID != id
                || loadedLanguage != resolvedLanguage
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

        let samples = try Self.loadSamples(from: audioURL)
        guard !samples.isEmpty else { throw LocalModelManagerError.modelNotDownloaded("empty audio") }

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
            let options = DecodingOptions(
                task: .transcribe,
                language: descriptor.englishOnly ? "en" : (language == "auto" ? nil : language),
                temperature: 0,
                usePrefillPrompt: true,
                usePrefillCache: true,
                skipSpecialTokens: true,
                chunkingStrategy: .vad
            )
            let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw LocalModelManagerError.modelNotDownloaded("empty transcript")
            }
            return text

        case .sherpaOnnx:
            let sherpaRecognizer = try ensureSherpaRecognizer(
                descriptor: descriptor,
                folder: folder,
                resolvedLanguage: resolvedLanguage
            )
            let text = await Task.detached(priority: .userInitiated) {
                sherpaRecognizer.transcribe(samples)
            }.value
            guard !text.isEmpty else {
                throw LocalModelManagerError.modelNotDownloaded("empty transcript")
            }
            return text
        }
    }

    private func ensureWhisperKit(
        descriptor: LocalModelDescriptor,
        folder: URL,
        tokenizerFolder: URL
    ) async throws -> WhisperKit {
        if loadedModelID != descriptor.id || whisperKit == nil {
            sherpaRecognizer = nil
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
    ) throws -> SherpaRecognizer {
        let files = try LocalModelIntegrity.sherpaModel(for: descriptor.id).files
        try LocalModelIntegrity.verifySizes(in: folder, files: files)
        if loadedModelID != descriptor.id
            || loadedLanguage != resolvedLanguage
            || sherpaRecognizer == nil
        {
            whisperKit = nil
            sherpaRecognizer = try SherpaRecognizer.create(
                model: descriptor,
                directory: folder,
                language: resolvedLanguage,
                // ONNX Runtime's CPU pool benefits from a bounded number of
                // workers on iPhone; using every logical core throttles long
                // recordings and competes with audio/UI work.
                threads: max(2, min(ProcessInfo.processInfo.processorCount - 2, 4))
            )
            loadedModelID = descriptor.id
            loadedLanguage = resolvedLanguage
        }
        guard let sherpaRecognizer else {
            throw LocalModelManagerError.engineLoadFailed(descriptor.id)
        }
        return sherpaRecognizer
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
