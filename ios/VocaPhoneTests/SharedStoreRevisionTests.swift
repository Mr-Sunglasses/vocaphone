import Foundation
import Testing

/// The keyboard and the app write the same session record from two processes.
/// These are the rules that stop the app's write after an await from erasing
/// the keyboard's Cancel.
struct SharedStoreRevisionTests {
    private static func temporaryStore() -> (SharedStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (SharedStore(rootOverride: root), root)
    }

    private static func launching() throws -> SessionRecord {
        var record = SessionRecord()
        try record.transition(to: .launchingApp)
        return record
    }

    @Test func aCompareAndSwapAtTheStoredRevisionWritesTheNextOne() throws {
        let (store, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try store.save(Self.launching())

        var claimed = stored
        claimed.claimedAt = Date(timeIntervalSince1970: 2_000)
        let written = try store.save(claimed, expectingRevision: stored.revision)

        #expect(written.revision == stored.revision + 1)
        #expect(try store.load(stored.sessionID)?.claimedAt == claimed.claimedAt)
        #expect(try store.load(stored.sessionID)?.revision == written.revision)
    }

    @Test func aCompareAndSwapAgainstAnOlderRevisionIsRejected() throws {
        let (store, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try store.save(Self.launching())
        var newer = stored
        try newer.transition(to: .canceled)
        try store.save(newer)

        var stale = stored
        try stale.transition(to: .recording)
        #expect(throws: SharedStoreError.revisionConflict) {
            try store.save(stale, expectingRevision: stored.revision)
        }
        #expect(try store.load(stored.sessionID)?.state == .canceled)
    }

    /// A session somebody deleted is not resurrected by a conditional write.
    @Test func aCompareAndSwapOnAMissingRecordIsRejected() throws {
        let (store, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: SharedStoreError.revisionConflict) {
            try store.save(try Self.launching(), expectingRevision: 1)
        }
    }

    /// Every write is a new revision, even one made from a stale copy. The
    /// keyboard's Cancel is built on whatever it last read; if it could land
    /// on the same number the app is about to expect, the app's
    /// compare-and-swap would pass straight over it.
    @Test func anUnconditionalWriteAlwaysMovesTheRevisionForward() throws {
        let (store, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try store.save(Self.launching())
        let keyboardCopy = original

        var appCopy = original
        appCopy.claimedAt = Date(timeIntervalSince1970: 2_000)
        appCopy = try store.save(appCopy, expectingRevision: original.revision)

        var cancel = keyboardCopy
        try cancel.transition(to: .canceled)
        #expect(cancel.revision == appCopy.revision)
        let written = try store.save(cancel)

        #expect(written.revision > appCopy.revision)
        #expect(throws: SharedStoreError.revisionConflict) {
            try store.save(appCopy, expectingRevision: appCopy.revision)
        }
    }

    /// The bug: the app claims the hand-off, awaits the microphone and the
    /// socket, and writes `recording`. A Cancel the keyboard wrote during the
    /// wait used to be overwritten — the mic kept recording and the bar flipped
    /// back to Listening.
    @Test func aCancelWrittenDuringTheAppsWaitIsNotOverwritten() throws {
        let (store, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let requested = try store.save(Self.launching())

        // The app claims it.
        var app = try #require(try store.load(requested.sessionID))
        app.claimedAt = Date(timeIntervalSince1970: 2_000)
        app = try store.saveUnlessEnded(app)

        // While the app awaits, the keyboard cancels from its own copy.
        var keyboard = try #require(try store.load(requested.sessionID))
        try keyboard.transition(to: .canceled)
        try store.save(keyboard)

        // The app comes back and writes the recording state.
        try app.transition(to: .recording)
        #expect(throws: CancellationError.self) { try store.saveUnlessEnded(app) }
        #expect(try store.load(requested.sessionID)?.state == .canceled)
    }

    /// Expiry is the keyboard's watchdog, and ends the session just as surely.
    @Test func anExpiredSessionIsNotRevivedEither() throws {
        let (store, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var app = try store.save(Self.launching())
        var expired = app
        try expired.transition(to: .expired)
        try store.save(expired)

        try app.transition(to: .recording)
        #expect(throws: CancellationError.self) { try store.saveUnlessEnded(app) }
        #expect(try store.load(app.sessionID)?.state == .expired)
    }

    /// A non-terminal change from the keyboard — the hand-off moving to
    /// `awaitingReturn` — is not a Cancel, and the app's write still lands.
    @Test func aLiveSessionStillTakesTheAppsWrite() throws {
        let (store, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var app = try store.save(Self.launching())
        var keyboard = app
        try keyboard.transition(to: .awaitingReturn)
        try store.save(keyboard)

        try app.transition(to: .recording)
        let written = try store.saveUnlessEnded(app)
        #expect(written.state == .recording)
        #expect(try store.load(app.sessionID)?.state == .recording)
    }

    @Test func aDeletedSessionIsNotRecreatedByTheApp() throws {
        let (store, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CancellationError.self) {
            try store.saveUnlessEnded(try Self.launching())
        }
        #expect(try store.recent().isEmpty)
    }

    /// Two stores over one container stand in for the two processes: each has
    /// its own file descriptor for the lock, as the app and the keyboard do.
    /// Every increment is a read, a change and a conditional write; if a read
    /// and a write ever interleaved, an increment would be lost.
    @Test func concurrentConditionalWritersNeverLoseAnUpdate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = [SharedStore(rootOverride: root), SharedStore(rootOverride: root)]
        var record = try Self.launching()
        record.recordedSeconds = 0
        try stores[0].save(record)
        let id = record.sessionID
        let perWriter = 40

        DispatchQueue.concurrentPerform(iterations: stores.count) { index in
            let store = stores[index]
            for _ in 0..<perWriter {
                while true {
                    guard var current = try? store.load(id) else { continue }
                    let expected = current.revision
                    current.recordedSeconds = (current.recordedSeconds ?? 0) + 1
                    if (try? store.save(current, expectingRevision: expected)) != nil { break }
                }
            }
        }

        let final = try #require(try stores[1].load(id))
        #expect(final.recordedSeconds == Double(stores.count * perWriter))
    }
}
