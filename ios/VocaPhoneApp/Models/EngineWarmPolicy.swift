import Foundation

/// Whether loading a speech model *ahead* of a dictation is worth the memory.
///
/// A warm-up is a guess: nobody has asked for the model yet, and loading it
/// costs as much memory as the dictation would. Guessing wrong on a phone that
/// is already short is an out-of-memory kill in the middle of setup, which is
/// far worse than the few seconds the guess was meant to save — so a warm-up
/// only happens with room to spare. A dictation never asks this; it loads
/// regardless, because then the model is needed.
enum EngineWarmPolicy {
    /// Left over after the model is in: the recorder, the interface, and the
    /// keyboard extension that is about to be opened on the same phone.
    static let headroomBytes: Int64 = 512 * 1024 * 1024

    /// - Parameters:
    ///   - availableBytes: `os_proc_available_memory()`. Zero means the
    ///     platform would not say — the simulator, for one — and is treated as
    ///     room, since refusing every warm-up there helps nobody.
    ///   - modelBytes: the model's download size, which is close to what its
    ///     weights occupy once loaded.
    ///   - residentBytes: a model already loaded that this load would replace.
    ///     Engines are released before the next is built, so its memory counts
    ///     as available.
    static func hasRoom(
        availableBytes: UInt64,
        modelBytes: Int64,
        residentBytes: Int64 = 0
    ) -> Bool {
        guard availableBytes > 0 else { return true }
        let usable = Int64(clamping: availableBytes) + max(residentBytes, 0)
        return usable >= max(modelBytes, 0) + headroomBytes
    }
}
