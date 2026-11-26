import Foundation
import Testing
import UIKit

/// The number row, the one-handed keyboard, the edit row's Undo and the
/// clipboard history: the parts of each that are rules rather than drawing.
@MainActor
struct KeyboardSurfacesTests {
    private static let width: CGFloat = 402
    private static let portrait = UITraitCollection { $0.verticalSizeClass = .regular }

    private static func grid(
        numberRow: Bool = false,
        oneHanded: OneHandedKeyboard = .off,
        plane: KeyPlane = .letters
    ) -> KeyGridView {
        let metrics = KeyboardMetrics.resolved(for: portrait, preference: .standard)
            .withNumberRow(numberRow)
        let grid = KeyGridView(metrics: metrics, palette: KeyboardPalette(isDark: false))
        grid.showsNumberRow = numberRow
        grid.plane = plane
        grid.frame = CGRect(x: 0, y: 0, width: width, height: metrics.gridHeight)
        grid.oneHandedSide = oneHanded
        grid.layoutIfNeeded()
        return grid
    }

    // MARK: - Number row

    @Test func numberRowStartsOffLikeApplesKeyboard() {
        #expect(!KeyboardDefaults.numberRow)
        #expect(KeyboardDefaults.oneHandedKeyboard == .off)
        #expect(!KeyboardDefaults.clipboardHistory)
    }

    @Test func numberRowIsTheDigitsAboveTheLettersOnly() {
        let letters = KeyLayout.rows(for: .letters, includesGlobe: false, returnIsProminent: false, numberRow: true)
        #expect(letters.count == 5)
        #expect(letters[0].keys.map(\.cap) == "1234567890".map { .character(String($0)) })
        let numbers = KeyLayout.rows(for: .numbers, includesGlobe: false, returnIsProminent: false, numberRow: true)
        #expect(numbers.count == 4)
        let pad = KeyLayout.rows(for: .phonePad, includesGlobe: false, returnIsProminent: false, numberRow: true)
        #expect(pad.count == 4)
    }

    @Test func numberRowMakesTheKeyboardOneRowTaller() {
        let base = KeyboardMetrics.resolved(for: Self.portrait, preference: .standard)
        let tall = base.withNumberRow(true)
        #expect(tall.gridHeight == base.gridHeight + base.keyHeight + base.rowGap)
        #expect(tall.keyHeight(forRows: 5) == base.keyHeight)
    }

    /// The numbers plane under a number row keeps the keyboard's height: its
    /// four rows stretch rather than leaving a band, so `123` never resizes
    /// the host app.
    @Test func fourRowPlanesStretchToTheNumberRowHeight() {
        let grid = Self.grid(numberRow: true, plane: .numbers)
        let bottom = grid.keyViews.map(\.frame.maxY).max() ?? 0
        #expect(abs(bottom - grid.metrics.gridHeight) < 0.5)
        let letters = Self.grid(numberRow: true)
        let digits = letters.keyViews.prefix(10)
        #expect(digits.allSatisfy { $0.frame.minY == 0 })
        #expect(abs((letters.keyViews.map(\.frame.maxY).max() ?? 0) - letters.metrics.gridHeight) < 0.5)
    }

    /// The digits sit on QWERTY's columns, and an eleven-column alphabet does
    /// not push `0` off the end.
    @Test func numberRowLinesUpWithTheLetterColumns() {
        let grid = Self.grid(numberRow: true)
        let digits = Array(grid.keyViews.prefix(10))
        let topLetters = Array(grid.keyViews[10..<20])
        for (digit, letter) in zip(digits, topLetters) {
            #expect(abs(digit.frame.midX - letter.frame.midX) < 0.5)
        }
        let russian = Self.grid(numberRow: true)
        if let layout = TypingLayout.catalogue.first(where: { $0.rows.first?.count == 11 }) {
            russian.layout = layout
            russian.layoutIfNeeded()
            #expect((russian.keyViews.prefix(10).map(\.frame.maxX).max() ?? 0) <= Self.width)
        }
    }

    // MARK: - One-handed

    @Test func oneHandedKeysLeanTowardTheChosenSide() {
        let gutter = KeyGridView.oneHandedGutter(forWidth: Self.width)
        let left = Self.grid(oneHanded: .left)
        #expect((left.keyViews.map(\.frame.maxX).max() ?? 0) <= Self.width - gutter + 0.5)
        let right = Self.grid(oneHanded: .right)
        #expect((right.keyViews.map(\.frame.minX).min() ?? 0) >= gutter - 0.5)
        // The keys keep about five sixths of the width, as Apple's do.
        #expect(gutter > 50 && gutter < 80)
    }

    /// The strip belongs to the chevron, and nothing in it types.
    @Test func theOneHandedStripIsTheChevronNotAKey() {
        let grid = Self.grid(oneHanded: .left)
        let inStrip = CGPoint(x: Self.width - 10, y: grid.bounds.midY)
        let hit = grid.hitTest(inStrip, with: nil)
        #expect(hit is UIButton)
        #expect(grid.hitTest(CGPoint(x: 20, y: grid.bounds.midY), with: nil) === grid)
        var restored = false
        grid.onRestoreFullWidth = { restored = true }
        (hit as? UIButton)?.sendActions(for: .touchUpInside)
        #expect(restored)
    }

    @Test func fullWidthLeavesNoStrip() {
        let grid = Self.grid()
        #expect(grid.keyArea == grid.bounds)
        #expect(grid.hitTest(CGPoint(x: Self.width - 2, y: grid.bounds.midY), with: nil) === grid)
    }

    // MARK: - Undo

    @Test func undoTakesBackAnInsertionStillAtTheCursor() {
        let edit = KeyboardEdit.inserted(text: "pasted", following: "", documentID: "a")
        #expect(KeyboardEditUndo.step(for: edit, before: "Hi pasted", after: "", currentDocumentID: "a")
            == .deleteBackward(count: 6))
        // Typed past it: the keyboard would delete what the user typed.
        #expect(KeyboardEditUndo.step(for: edit, before: "Hi pasted!", after: "", currentDocumentID: "a")
            == .unavailable)
        // Another field.
        #expect(KeyboardEditUndo.step(for: edit, before: "Hi pasted", after: "", currentDocumentID: "b")
            == .unavailable)
    }

    @Test func undoPutsBackACutOnlyWhereItCameFrom() {
        let edit = KeyboardEdit.removed(text: "world", before: "Hello ", after: "!", documentID: "a")
        #expect(KeyboardEditUndo.step(for: edit, before: "Hello ", after: "!", currentDocumentID: "a")
            == .insert("world"))
        #expect(KeyboardEditUndo.step(for: edit, before: "Hello x", after: "!", currentDocumentID: "a")
            == .unavailable)
        #expect(KeyboardEditUndo.step(for: edit, before: "Hello ", after: "!", currentDocumentID: "b")
            == .unavailable)
    }

    @Test func cutAndCopyNeedASelectionAndFullAccess() {
        #expect(!KeyboardEditAvailability(hasSelection: true, hasFullAccess: false).canCutOrCopy)
        #expect(!KeyboardEditAvailability(hasSelection: false, hasFullAccess: true).canCutOrCopy)
        #expect(KeyboardEditAvailability(hasSelection: true, hasFullAccess: true).canCutOrCopy)
    }

    // MARK: - Clipboard history

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func copyingAgainMovesAClipToTheTopAndKeepsItsPin() {
        var history = ClipboardHistory()
        history.add("one", at: Self.now)
        history.add("two", at: Self.now.addingTimeInterval(1))
        history.togglePin(history.clips[1].id)
        history.add("one", at: Self.now.addingTimeInterval(2))
        #expect(history.clips.map(\.text) == ["one", "two"])
        #expect(history.clips[0].isPinned)
    }

    @Test func historyKeepsThirtyAndDropsTheOldestUnpinnedFirst() {
        var history = ClipboardHistory()
        history.add("oldest", at: Self.now)
        history.togglePin(history.clips[0].id)
        for index in 0..<40 {
            history.add("clip \(index)", at: Self.now.addingTimeInterval(Double(index + 1)))
        }
        #expect(history.clips.count == ClipboardHistoryPolicy.maximumClips)
        #expect(history.clips.contains { $0.text == "oldest" && $0.isPinned })
        #expect(history.clips.first?.text == "clip 39")
        #expect(!history.clips.contains { $0.text == "clip 0" })
    }

    @Test func expiredClipsGoButPinsStay() {
        var history = ClipboardHistory()
        history.add("pinned", at: Self.now)
        history.togglePin(history.clips[0].id)
        history.add("old", at: Self.now)
        history.add("new", at: Self.now.addingTimeInterval(3_000))
        history.prune(retention: ClipboardRetention.hour.interval, now: Self.now.addingTimeInterval(4_000))
        #expect(history.clips.map(\.text) == ["new", "pinned"])
        history.removeUnpinned()
        #expect(history.clips.map(\.text) == ["pinned"])
    }

    @Test func passwordManagerClipsAndHugeOrBlankTextAreNotKept() {
        #expect(!ClipboardHistoryPolicy.mayKeep(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(!ClipboardHistoryPolicy.mayKeep(types: ["org.nspasteboard.TransientType"]))
        #expect(ClipboardHistoryPolicy.mayKeep(types: ["public.utf8-plain-text"]))
        #expect(!ClipboardHistoryPolicy.mayKeep(text: "   \n"))
        #expect(!ClipboardHistoryPolicy.mayKeep(text: String(repeating: "a", count: 2_001)))
        var history = ClipboardHistory()
        history.add(" ", at: Self.now)
        #expect(history.clips.isEmpty)
    }

    @Test func storeRoundTripsAndClearsEverything() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        let store = ClipboardHistoryStore(fileURL: url)
        defer { store.removeAll() }
        store.update(retention: ClipboardRetention.week.interval, now: Self.now) { $0.add("kept", at: Self.now) }
        #expect(store.load().clips.map(\.text) == ["kept"])
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        // A week later the unpinned clip has expired.
        #expect(store.current(retention: ClipboardRetention.day.interval, now: Self.now.addingTimeInterval(8 * 86_400))
            .clips.isEmpty)
        store.update(retention: ClipboardRetention.week.interval, now: Self.now) { $0.add("again", at: Self.now) }
        store.removeAll()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// The clipboard is read only when it changed, only with history on, and
    /// never in a password field — and never when the copy is marked secret.
    @Test func captureReadsOncePerCopyAndOnlyWhenAllowed() {
        let suite = "clipboard-capture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        defer { defaults?.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        let store = ClipboardHistoryStore(fileURL: url)
        defer { store.removeAll() }
        let board = FakeClipboard(text: "hello", changeCount: 4)

        func capture(enabled: Bool = true, field: Bool = true) -> Bool {
            ClipboardCapture.captureIfChanged(
                board, isEnabled: enabled, fieldAllows: field, store: store,
                retention: 3_600, defaults: defaults, now: Self.now
            )
        }

        #expect(!capture(enabled: false))
        #expect(!capture(field: false))
        #expect(board.reads == 0)
        #expect(capture())
        #expect(board.reads == 1)
        // Same copy: not read again.
        #expect(!capture())
        #expect(board.reads == 1)
        // A password manager's copy is skipped without reading its text.
        board.changeCount = 5
        board.text = "secret"
        board.firstItemTypes = ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]
        #expect(!capture())
        #expect(board.reads == 1)
        #expect(store.load().clips.map(\.text) == ["hello"])
    }

    private static func captureFixture() -> (UserDefaults?, String, ClipboardHistoryStore) {
        let suite = "clipboard-capture-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        return (UserDefaults(suiteName: suite), suite, ClipboardHistoryStore(fileURL: url))
    }

    /// A password copied from Notes, with no secret marker, and pasted into a
    /// password field: the refusal marks the copy seen, so opening the panel
    /// later in an ordinary field does not read it into the history.
    @Test func aCopyPastedWhereItCannotBeKeptIsNeverCapturedLater() {
        let (defaults, suite, store) = Self.captureFixture()
        defer { defaults?.removePersistentDomain(forName: suite); store.removeAll() }
        let board = FakeClipboard(text: "hunter2", changeCount: 9)
        #expect(!ClipboardCapture.keep(
            "hunter2", types: board.firstItemTypes, changeCount: 9,
            isEnabled: true, fieldAllows: false, store: store, defaults: defaults, now: Self.now
        ))
        #expect(!ClipboardCapture.captureIfChanged(
            board, isEnabled: true, fieldAllows: true, store: store,
            retention: 3_600, defaults: defaults, now: Self.now
        ))
        #expect(board.reads == 0)
        #expect(store.load().clips.isEmpty)

        // The same for a copy marked secret, and with the history off.
        board.changeCount = 10
        #expect(!ClipboardCapture.keep(
            "otp", types: ["org.nspasteboard.TransientType"], changeCount: 10,
            isEnabled: true, fieldAllows: true, store: store, defaults: defaults, now: Self.now
        ))
        board.changeCount = 11
        #expect(!ClipboardCapture.keep(
            "x", changeCount: 11, isEnabled: false, fieldAllows: true,
            store: store, defaults: defaults, now: Self.now
        ))
        #expect(!ClipboardCapture.hasUnseenCopy(board, defaults: defaults))
    }

    /// Whatever was on the clipboard while a password field had the keyboard
    /// is never kept, though nothing was pasted.
    @Test func aCopyThatMetAPasswordFieldIsNeverCaptured() {
        let (defaults, suite, store) = Self.captureFixture()
        defer { defaults?.removePersistentDomain(forName: suite); store.removeAll() }
        let board = FakeClipboard(text: "hunter2", changeCount: 3)
        ClipboardCapture.noteSecretField(board, defaults: defaults)
        #expect(!ClipboardCapture.captureIfChanged(
            board, isEnabled: true, fieldAllows: true, store: store,
            retention: 3_600, defaults: defaults, now: Self.now
        ))
        #expect(board.reads == 0)
        // The next copy, made after the field, is an ordinary one.
        board.changeCount = 4
        board.text = "lunch at 1"
        #expect(ClipboardCapture.captureIfChanged(
            board, isEnabled: true, fieldAllows: true, store: store,
            retention: 3_600, defaults: defaults, now: Self.now
        ))
    }

    /// A huge copy is refused on its byte count, before it is decoded.
    @Test func aHugeCopyIsNotDecoded() {
        let big = Data(repeating: 0x61, count: ClipboardHistoryPolicy.maximumBytes + 1)
        #expect(ClipboardHistoryPolicy.text(from: big, type: "public.utf8-plain-text") == nil)
        #expect(ClipboardHistoryPolicy.text(from: Data("hi".utf8), type: "public.utf8-plain-text") == "hi")
        let utf16 = "hé".data(using: .utf16LittleEndian) ?? Data()
        #expect(ClipboardHistoryPolicy.text(from: utf16, type: "public.utf16-plain-text") == "hé")
        // Big enough for any clip the history keeps.
        #expect(ClipboardHistoryPolicy.maximumBytes >= 4 * ClipboardHistoryPolicy.maximumCharacters)

        let (defaults, suite, store) = Self.captureFixture()
        defer { defaults?.removePersistentDomain(forName: suite); store.removeAll() }
        let board = FakeClipboard(text: String(repeating: "a", count: 100_000), changeCount: 1)
        #expect(!ClipboardCapture.captureIfChanged(
            board, isEnabled: true, fieldAllows: true, store: store,
            retention: 3_600, defaults: defaults, now: Self.now
        ))
        #expect(store.load().clips.isEmpty)
    }

    /// Expired clips leave the file when the keyboard appears or the app
    /// opens, not only when the panel does; off deletes the file.
    @Test func enforcingRetentionPrunesTheFileAndOffDeletesIt() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        let store = ClipboardHistoryStore(fileURL: url)
        defer { store.removeAll() }
        // Nothing there: nothing is created.
        store.enforce(isEnabled: true, retention: 3_600, now: Self.now)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        store.update(retention: ClipboardRetention.week.interval, now: Self.now) {
            $0.add("old", at: Self.now)
            $0.add("pinned", at: Self.now)
            $0.togglePin($0.clips[0].id)
            $0.add("new", at: Self.now.addingTimeInterval(3_000))
        }
        store.enforce(isEnabled: true, retention: 3_600, now: Self.now.addingTimeInterval(4_000))
        #expect(store.load().clips.map(\.text) == ["new", "pinned"])
        store.enforce(isEnabled: false, retention: 3_600, now: Self.now.addingTimeInterval(4_000))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
private final class FakeClipboard: ClipboardReading {
    var text: String?
    var changeCount: Int
    var firstItemTypes = ["public.utf8-plain-text"]
    private(set) var reads = 0

    init(text: String?, changeCount: Int) {
        self.text = text
        self.changeCount = changeCount
    }

    var hasStrings: Bool { text != nil }

    func plainTextData() -> (type: String, data: Data)? {
        reads += 1
        return text.map { ("public.utf8-plain-text", Data($0.utf8)) }
    }
}
