import CryptoKit
import Foundation

struct LocalModelIntegrityError: LocalizedError, Equatable {
    let model: String
    let path: String
    let expected: String
    let actual: String

    var errorDescription: String? {
        "The downloaded model failed its SHA-256 check. It was discarded; try again."
    }
}

/// Verifies a model directory before any Core ML model is initialized.
///
/// Two levels exist deliberately. `verifyDigests` hashes every pinned file and
/// is what a download must pass. `verifySizes` only stats them, and is what a
/// launch or a model load uses: hashing 1.6 GB on every launch stalled the app
/// for seconds, and a file inside the app container cannot change size-for-size
/// without the app itself rewriting it. A directory that has passed
/// `verifyDigests` records a marker so the cheap path knows the expensive one
/// already ran against these exact pins.
enum LocalModelIntegrity {
    struct Manifest: Decodable, Sendable {
        let repository: String
        let revision: String
        let models: [String: ModelManifest]
        let tokenizers: [String: TokenizerManifest]
    }

    struct SherpaManifest: Decodable, Sendable {
        let models: [String: SherpaModelManifest]
    }

    struct SherpaModelManifest: Decodable, Sendable {
        let repository: String
        let revision: String
        let files: [ManifestFile]
    }

    struct ModelManifest: Decodable, Sendable {
        let files: [ManifestFile]
    }

    /// WhisperKit resolves the tokenizer separately from the Core ML weights, so
    /// the tokenizer repository carries its own revision.
    struct TokenizerManifest: Decodable, Sendable {
        let revision: String
        let files: [ManifestFile]
    }

    struct ManifestFile: Decodable, Sendable {
        let path: String
        let size: Int64
        let sha256: String?
    }

    /// Written inside a directory whose digests have all been checked.
    static let markerFileName = ".vocaphone-verified"

    private static let manifest: Manifest? = {
        guard let url = Bundle.main.url(forResource: "local_model_pins", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }()

    private static let sherpaManifest: SherpaManifest? = {
        guard let url = Bundle.main.url(forResource: "sherpa_model_pins", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(SherpaManifest.self, from: data)
    }()

    static var repository: String? { manifest?.repository }
    static var revision: String? { manifest?.revision }

    static func files(for modelIdentifier: String) throws -> [ManifestFile] {
        guard let files = manifest?.models[modelIdentifier]?.files else {
            throw LocalModelManagerError.integrityManifestMissing(modelIdentifier)
        }
        return files
    }

    static func sherpaModel(for modelIdentifier: String) throws -> SherpaModelManifest {
        guard let model = sherpaManifest?.models[modelIdentifier] else {
            throw LocalModelManagerError.integrityManifestMissing(modelIdentifier)
        }
        return model
    }

    static func tokenizer(for repository: String) throws -> TokenizerManifest {
        guard let tokenizer = manifest?.tokenizers[repository] else {
            throw LocalModelManagerError.tokenizerManifestMissing(repository)
        }
        return tokenizer
    }

    // MARK: - Verification

    /// Stats every pinned file and confirms the marker matches these pins.
    static func verifySizes(
        in directory: URL,
        files: [ManifestFile],
        requiringMarker: Bool = true
    ) throws {
        for file in files {
            let url = directory.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LocalModelManagerError.integrityFileMissing(file.path)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard actualSize == file.size else {
                throw LocalModelManagerError.integritySizeMismatch(file.path)
            }
        }
        if requiringMarker, !markerMatches(fingerprint(of: files), in: directory) {
            throw LocalModelManagerError.integrityUnverified(directory.lastPathComponent)
        }
    }

    /// Hashes every pinned file that carries a digest, then records the marker.
    static func verifyDigests(
        in directory: URL,
        files: [ManifestFile],
        modelIdentifier: String? = nil
    ) throws {
        try verifySizes(in: directory, files: files, requiringMarker: false)
        for file in files {
            let url = directory.appendingPathComponent(file.path)
            try verify(file: url, against: file, modelIdentifier: modelIdentifier)
        }
        try writeMarker(fingerprint(of: files), in: directory)
    }

    static func verify(
        file url: URL,
        against expectedFile: ManifestFile,
        modelIdentifier: String? = nil
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == expectedFile.size else {
            throw LocalModelManagerError.integritySizeMismatch(expectedFile.path)
        }
        if let expected = expectedFile.sha256 {
            let actual = try sha256(of: url)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw LocalModelIntegrityError(
                    model: modelIdentifier ?? "unknown", path: expectedFile.path,
                    expected: expected, actual: actual
                )
            }
        }
    }

    static func sha256(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while true {
            let data = input.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Marker

    /// Identifies the exact pin set a directory was verified against, so a build
    /// that changes a pin invalidates the marker instead of trusting stale bytes.
    static func fingerprint(of files: [ManifestFile]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data("\(file.path)|\(file.size)|\(file.sha256 ?? "")\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func markerMatches(_ fingerprint: String, in directory: URL) -> Bool {
        let url = directory.appendingPathComponent(markerFileName)
        guard let recorded = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return recorded.trimmingCharacters(in: .whitespacesAndNewlines) == fingerprint
    }

    static func writeMarker(_ fingerprint: String, in directory: URL) throws {
        try Data(fingerprint.utf8).write(
            to: directory.appendingPathComponent(markerFileName), options: .atomic
        )
    }
}

enum LocalModelManagerError: LocalizedError, Equatable {
    case unsupportedModel(String)
    case integrityManifestMissing(String)
    case tokenizerManifestMissing(String)
    case integrityFileMissing(String)
    case integritySizeMismatch(String)
    case integrityUnverified(String)
    case modelNotDownloaded(String)
    case noModelContainer
    case insufficientMemory(requiredGB: Int)
    case insufficientStorage(freeBytes: Int64, requiredBytes: Int64)
    case engineLoadFailed(String)
    case downloadFailed(path: String, statusCode: Int?)

    var errorDescription: String? {
        switch self {
        case let .unsupportedModel(id): "This on-device model is not supported: \(id)."
        case .integrityManifestMissing: "The bundled model integrity manifest is missing."
        case let .tokenizerManifestMissing(repository):
            "No pinned tokenizer is bundled for \(repository)."
        case let .integrityFileMissing(path): "The model is incomplete: \(path)."
        case let .integritySizeMismatch(path): "The model file has an unexpected size: \(path)."
        case let .integrityUnverified(name):
            "\(name) has not been verified on this device. Download it again."
        case let .modelNotDownloaded(id): "Download \(id) before using on-device transcription."
        case .noModelContainer: "The app's model directory is unavailable."
        case let .insufficientMemory(requiredGB):
            "This model needs a device with at least \(requiredGB) GB of memory."
        // Says what to do, not only what is wrong: the two figures together are
        // what tells someone how much they have to clear.
        case let .insufficientStorage(freeBytes, requiredBytes):
            "This model needs \(DownloadReadiness.byteLabel(requiredBytes)) free and this "
                + "iPhone has \(DownloadReadiness.byteLabel(freeBytes)). "
                + "Free up some space and try again."
        case let .engineLoadFailed(id): "Could not load the on-device model \(id)."
        case let .downloadFailed(path, statusCode):
            if let statusCode {
                "Could not download \(path) (HTTP \(statusCode)). Check your internet connection and try again."
            } else {
                "Could not download \(path). Check your internet connection and try again."
            }
        }
    }
}
