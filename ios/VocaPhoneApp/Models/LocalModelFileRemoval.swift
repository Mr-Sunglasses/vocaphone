import Foundation

/// A successful filesystem call is not enough if the folder is still present.
/// Keep this check separate so the failure path can be exercised without
/// modifying the app's real model store.
enum LocalModelFileRemoval {
    static func remove(
        at folder: URL,
        using removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        do {
            try removeItem(folder)
        } catch {
            // A removal may finish and then report an error. The folder's
            // actual presence is what determines whether it remains usable.
            if FileManager.default.fileExists(atPath: folder.path) { throw error }
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
