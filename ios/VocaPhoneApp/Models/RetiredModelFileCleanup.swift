import Foundation

/// File removal can take seconds for old Core ML folders, so callers run this
/// off the main actor and apply its result to preferences only after success.
enum RetiredModelFileCleanup {
    struct Result: Sendable {
        let deleted: [String]
        let failed: [String]
    }

    static func delete(
        in root: URL,
        ids: [String],
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> Result {
        var deleted: [String] = []
        var failed: [String] = []
        for id in ids {
            let folder = root.appendingPathComponent(id, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            do {
                try remove(folder)
                deleted.append(id)
            } catch {
                failed.append(id)
            }
        }
        return Result(deleted: deleted, failed: failed)
    }
}
