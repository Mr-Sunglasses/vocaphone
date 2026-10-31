import CryptoKit
import Foundation
import Testing

/// Mirrors android/.../local/GrammarModelStoreTest.kt and GrammarModelCatalogTest.kt.
@MainActor
struct GrammarModelStoreTests {
    private nonisolated static let bodies = ["model.onnx": "pretend weights", "labels.json": "[\"KEEP\"]"]

    private nonisolated static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static let pins = LocalModelIntegrity.PinnedModelManifest(
        repository: "example/grammar",
        revision: String(repeating: "0", count: 40),
        files: bodies.keys.sorted().map { path in
            LocalModelIntegrity.ManifestFile(
                path: path, size: Int64(bodies[path]!.utf8.count), sha256: sha256(bodies[path]!)
            )
        }
    )

    private nonisolated static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grammar-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Serves `bodies` by file name, optionally replacing what one file returns.
    private nonisolated static func fetch(
        overriding overrides: [String: String] = [:],
        requested: Requests? = nil
    ) -> GrammarModelStore.Fetch {
        { url, progress in
            requested?.append(url)
            let name = url.lastPathComponent
            let body = overrides[name] ?? bodies[name] ?? ""
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("grammar-fetch-\(UUID().uuidString)")
            try Data(body.utf8).write(to: file)
            progress(Int64(body.utf8.count))
            return file
        }
    }

    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func append(_ url: URL) { lock.withLock { urls.append(url) } }
        var all: [URL] { lock.withLock { urls } }
    }

    @Test func downloadVerifiesCommitsAndMarksTheModel() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = Requests()
        let store = GrammarModelStore(pins: Self.pins, root: root, fetch: Self.fetch(requested: requests))
        #expect(!store.isReady)
        #expect(store.phase == .absent)

        try await store.download()

        #expect(store.isReady)
        #expect(store.phase == .ready)
        let directory = try #require(store.directory)
        #expect(directory == root.appendingPathComponent(GrammarModelStore.modelID, isDirectory: true))
        #expect(LocalModelIntegrity.markerMatches(
            LocalModelIntegrity.fingerprint(of: Self.pins.files), in: directory
        ))
        #expect(requests.all.map(\.path).sorted() == [
            "/example/grammar/resolve/\(Self.pins.revision)/labels.json",
            "/example/grammar/resolve/\(Self.pins.revision)/model.onnx",
        ])
        // Nothing staged is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers == [GrammarModelStore.modelID])
    }

    @Test func aChecksumMismatchDiscardsTheFilesAndSaysSo() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GrammarModelStore(
            pins: Self.pins, root: root, fetch: Self.fetch(overriding: ["model.onnx": "pretend weightz"])
        )

        await #expect(throws: LocalModelIntegrityError.self) { try await store.download() }

        #expect(!store.isReady)
        #expect(store.phase == .failed(.damaged))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers.isEmpty)
    }

    @Test func aServerErrorIsReportedAsOne() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GrammarModelStore(pins: Self.pins, root: root) { url, _ in
            throw LocalModelManagerError.downloadFailed(path: url.lastPathComponent, statusCode: 503)
        }

        await #expect(throws: LocalModelManagerError.self) { try await store.download() }

        #expect(store.phase == .failed(.serverError))
    }

    @Test func refreshHashesUnmarkedFilesOnceAndDeleteRemovesThem() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(GrammarModelStore.modelID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, body) in Self.bodies {
            try Data(body.utf8).write(to: directory.appendingPathComponent(path))
        }
        let store = GrammarModelStore(pins: Self.pins, root: root, fetch: Self.fetch())
        #expect(!store.isReady)

        await store.refresh()
        #expect(store.isReady)
        #expect(store.phase == .ready)

        #expect(store.delete())
        #expect(!store.isReady)
        #expect(store.phase == .absent)
    }

    @Test func aMarkerForOtherPinsIsNotTrusted() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(GrammarModelStore.modelID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, body) in Self.bodies {
            try Data(body.utf8).write(to: directory.appendingPathComponent(path))
        }
        let other = Self.pins.files.map {
            LocalModelIntegrity.ManifestFile(path: $0.path, size: $0.size, sha256: String(repeating: "0", count: 64))
        }
        try LocalModelIntegrity.writeMarker(LocalModelIntegrity.fingerprint(of: other), in: directory)

        #expect(!GrammarModelStore(pins: Self.pins, root: root, fetch: Self.fetch()).isReady)
    }

    @MainActor final class Holder {
        var store: GrammarModelStore?
    }

    /// Greptile on #415: a delete while the last file is landing must not let
    /// the download install the model afterwards.
    @Test func aDeleteDuringTheDownloadKeepsTheModelGone() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let holder = Holder()
        let serve = Self.fetch()
        let store = GrammarModelStore(pins: Self.pins, root: root) { url, progress in
            let file = try await serve(url, progress)
            if url.lastPathComponent == "model.onnx" {
                await MainActor.run { _ = holder.store?.delete() }
            }
            return file
        }
        holder.store = store

        await #expect(throws: CancellationError.self) { try await store.download() }

        #expect(!store.isReady)
        #expect(store.phase == .absent)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers.isEmpty)
    }

    /// Greptile on #415: a refresh that started over damaged files and finishes
    /// after a download installed good ones must not report the model missing.
    @Test func aRefreshFinishingAfterADownloadKeepsItReady() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Right sizes, wrong bytes and no marker: refresh has to hash them, and fails.
        let directory = root.appendingPathComponent(GrammarModelStore.modelID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, body) in Self.bodies {
            try Data(String(repeating: "x", count: body.utf8.count).utf8).write(to: directory.appendingPathComponent(path))
        }
        let store = GrammarModelStore(pins: Self.pins, root: root, fetch: Self.fetch())
        async let refreshed: Void = store.refresh()
        try await store.download()
        await refreshed

        #expect(store.isReady)
        #expect(store.phase == .ready)
    }

    /// A staging folder from an attempt the system killed is swept on the next launch.
    @Test func abandonedStagingFoldersAreRemoved() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let abandoned = root.appendingPathComponent(".download-\(GrammarModelStore.modelID)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: abandoned.appendingPathComponent("model.onnx"))

        _ = GrammarModelStore(pins: Self.pins, root: root, fetch: Self.fetch())

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }

    // MARK: - The bundled pins

    private static var bundledPins: LocalModelIntegrity.PinnedModelManifest {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("VocaPhoneApp/Models/grammar_model_pins.json")
            let manifest = try JSONDecoder().decode(
                LocalModelIntegrity.SherpaManifest.self, from: Data(contentsOf: url)
            )
            return try #require(manifest.models[GrammarModelStore.modelID])
        }
    }

    @Test func bundledPinsNameEveryFileAtAFixedRevision() throws {
        let pins = try Self.bundledPins
        #expect(pins.repository == "Mindscend/mindtype-tagger-v2.0")
        #expect(pins.revision.count == 40)
        #expect(Set(pins.files.map(\.path)) == Set([
            "mindtype_tagger.onnx", "tokenizer.json", "labels.json", "plausible_pairs.json", "config.json",
        ].map { "onnx/\($0)" }))
        for file in pins.files {
            #expect(file.sha256?.count == 64, "\(file.path)")
        }
        #expect(pins.files.reduce(0) { $0 + $1.size } == 28_115_617)
    }

    /// The grammar model transcribes nothing; it must never reach the speech picker.
    @Test func itIsNotASpeechModel() throws {
        let pins = try Self.bundledPins
        #expect(LocalModelCatalog.descriptor(for: GrammarModelStore.modelID) == nil)
        #expect(!LocalModelCatalog.all.contains { $0.repository == pins.repository })
    }

    @Test func downloadURLPinsTheRevision() {
        #expect(
            GrammarModelStore.url(repository: "VocaHQ/x", revision: "abc", path: "tokenizer.json").absoluteString
                == "https://huggingface.co/VocaHQ/x/resolve/abc/tokenizer.json?download=true"
        )
    }

    /// The pinned v2.0 files live in the repository's `onnx/` folder, and keep it on disk.
    @Test func filesInAFolderLandInThatFolder() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = LocalModelIntegrity.PinnedModelManifest(
            repository: Self.pins.repository,
            revision: Self.pins.revision,
            files: Self.pins.files.map {
                LocalModelIntegrity.ManifestFile(path: "onnx/\($0.path)", size: $0.size, sha256: $0.sha256)
            }
        )
        let store = GrammarModelStore(pins: nested, root: root, fetch: Self.fetch())

        try await store.download()

        #expect(store.isReady)
        let folder = try #require(store.modelDirectory)
        #expect(folder.standardizedFileURL == root
            .appendingPathComponent("\(GrammarModelStore.modelID)/onnx", isDirectory: true).standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.onnx").path))
    }

    @Test func aRetiredModelsFolderIsRemovedAndReported() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("grammar-old", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("model.onnx"))
        let store = GrammarModelStore(pins: Self.pins, root: root, fetch: Self.fetch())

        #expect(store.removeRetired(["grammar-old"]))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!store.removeRetired(["grammar-old"]))
    }

    @Test func theCurrentModelIsNeverRemovedAsRetired() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GrammarModelStore(pins: Self.pins, root: root, fetch: Self.fetch())
        try await store.download()

        #expect(!store.removeRetired([GrammarModelStore.modelID]))
        #expect(store.isReady)
        #expect(!GrammarModelStore.retiredModelIDs.contains(GrammarModelStore.modelID))
    }

    /// Greptile on #435: the first launch after an update removes the old
    /// folder; if that download fails, the next launch has no old folder to
    /// find and must still retry.
    @Test func aFailedUpgradeDownloadIsRetriedOnTheNextLaunch() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("grammar-old", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("model.onnx"))
        let offline = GrammarModelStore(pins: Self.pins, root: root) { _, _ in
            throw URLError(.notConnectedToInternet)
        }

        let firstLaunch = await offline.restore(retired: ["grammar-old"]) { true }
        #expect(!firstLaunch)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!offline.isReady)

        let nextLaunch = GrammarModelStore(pins: Self.pins, root: root, fetch: Self.fetch())
        let retried = await nextLaunch.restore(retired: ["grammar-old"]) { true }
        #expect(retried)
        #expect(nextLaunch.isReady)
    }

    @Test func noGrammarSettingOnMeansNoDownloadAtLaunch() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = Requests()
        let store = GrammarModelStore(pins: Self.pins, root: root, fetch: Self.fetch(requested: requests))

        let downloaded = await store.restore(retired: []) { false }
        #expect(!downloaded)

        #expect(!store.isReady)
        #expect(requests.all.isEmpty)
    }

    @Test func aReadyModelIsNotDownloadedAgainOrTheSettingsAsked() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = Requests()
        let store = GrammarModelStore(pins: Self.pins, root: root, fetch: Self.fetch(requested: requests))
        try await store.download()
        let before = requests.all.count
        var asked = false

        let downloaded = await store.restore(retired: []) {
            asked = true
            return true
        }
        #expect(!downloaded)

        #expect(store.isReady)
        #expect(!asked)
        #expect(requests.all.count == before)
    }
}
