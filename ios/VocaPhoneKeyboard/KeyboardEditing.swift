import UIKit

/// The edit row behind More: Undo, Cut, Copy and Paste, and the way into the
/// clipboard history.
///
/// A keyboard cannot reach the host app's undo stack, and there is no proxy
/// call that selects text, so Undo takes back only what this keyboard itself
/// last did (a paste, a clip, a dictation, a cut) and there is no Select All.
enum KeyboardEditAction: Equatable, Sendable {
    case undo
    case cut
    case copy
    case clipboard
    case oneHanded(OneHandedKeyboard)
}

/// What the edit row can offer right now. Read when More opens, because the
/// panel covers the keys and the selection cannot change under it.
struct KeyboardEditAvailability: Equatable, Sendable {
    var hasSelection = false
    var canUndo = false
    /// Writing to the clipboard, and the history, need Full Access.
    var hasFullAccess = false
    var showsClipboard = false
    /// iPhone portrait: the only place the one-handed keyboard applies.
    var offersOneHanded = false
    var oneHanded: OneHandedKeyboard = .off

    var canCutOrCopy: Bool { hasSelection && hasFullAccess }
}

/// Which side the one-handed keyboard is on when the keyboard appears.
///
/// The choice from More is written to the shared defaults, which without
/// Full Access may not keep it. Comparing against what was stored last time,
/// rather than against the choice in hand, means only a real change of the
/// stored value — made in the app's Settings — replaces it; otherwise the
/// side chosen in this keyboard session stands.
enum OneHandedPreferenceSync {
    static func resolve(
        stored: OneHandedKeyboard,
        lastStored: OneHandedKeyboard,
        current: OneHandedKeyboard
    ) -> OneHandedKeyboard {
        stored != lastStored ? stored : current
    }
}

/// Something this keyboard did to the document that Undo can take back.
enum KeyboardEdit: Equatable, Sendable {
    /// Text the keyboard put in at the cursor: a paste, a clip, a dictation.
    /// `following` is the document after the cursor when it went in, and
    /// `replaced` the selection it took the place of, if there was one.
    case inserted(text: String, following: String?, documentID: String?, replaced: String? = nil)
    /// Text the keyboard cut. `before` and `after` are the windows either
    /// side of the cursor straight after the cut.
    case removed(text: String, before: String?, after: String?, documentID: String?)
}

enum KeyboardEditUndo {
    enum Step: Equatable {
        case deleteBackward(count: Int)
        /// Takes the insertion back out and puts the selection it replaced
        /// back where it was.
        case replaceBackward(count: Int, restoring: String)
        case insert(String)
        /// The cursor or the document moved on; doing anything now would
        /// edit text the keyboard did not write.
        case unavailable
    }

    /// What Undo does to the document as it is now.
    static func step(
        for edit: KeyboardEdit,
        before: String?,
        after: String?,
        currentDocumentID: String?
    ) -> Step {
        switch edit {
        case let .inserted(text, following, documentID, replaced):
            // The same check dictation's Undo makes: the insertion is still
            // the tail of the text before the cursor, in the same field.
            guard InsertionUndo.isAtCursor(
                text,
                following: following,
                documentID: documentID,
                before: before,
                after: after,
                currentDocumentID: currentDocumentID
            ) else { return .unavailable }
            if let replaced, !replaced.isEmpty {
                return .replaceBackward(count: text.count, restoring: replaced)
            }
            return .deleteBackward(count: text.count)
        case let .removed(text, storedBefore, storedAfter, documentID):
            if let documentID, let currentDocumentID, documentID != currentDocumentID {
                return .unavailable
            }
            // Exactly where the cut left it: nothing typed since, and the
            // cursor where the text came out.
            guard (storedBefore ?? "") == (before ?? ""),
                  (storedAfter ?? "") == (after ?? "")
            else { return .unavailable }
            return .insert(text)
        }
    }
}

/// The clipboard, as much of it as clipboard history needs. `UIPasteboard`
/// conforms; tests stand in a fake.
@MainActor
protocol ClipboardReading: AnyObject {
    /// Says only that the clipboard changed. Reading it never asks the user.
    var changeCount: Int { get }
    var hasStrings: Bool { get }
    /// The types of the first item, for the do-not-keep markers.
    var firstItemTypes: [String] { get }
    /// The first item's plain text as raw bytes, with the type it came as.
    /// iOS may ask the user before answering. Bytes rather than a `String`,
    /// so a huge copy is measured and refused before it is decoded.
    func plainTextData() -> (type: String, data: Data)?
}

extension UIPasteboard: ClipboardReading {
    var firstItemTypes: [String] { types }

    func plainTextData() -> (type: String, data: Data)? {
        let available = types
        guard let type = ClipboardHistoryPolicy.plainTextTypes.first(where: available.contains),
              let data = data(forPasteboardType: type)
        else { return nil }
        return (type, data)
    }
}

/// When clipboard history reads the clipboard: only when asked.
///
/// Never on a timer and never when the keyboard appears. The two moments it
/// reads are the person opening the clipboard panel and tapping Paste — both
/// a request for the clipboard — and it reads once per copy, by
/// `changeCount`, so opening the panel twice does not ask twice. It also
/// keeps what the keyboard itself copies or cuts.
@MainActor
enum ClipboardCapture {
    static let capturedChangeCountKey = "clipboardHistoryCapturedChangeCount"
    /// The last copy that must never be kept: seen in a secret field, pasted
    /// into one, or marked do-not-keep. Separate from "seen", because a copy
    /// can be seen and still be pasted later in an ordinary field.
    static let refusedChangeCountKey = "clipboardHistoryRefusedChangeCount"

    static func isRefused(_ changeCount: Int, defaults: UserDefaults?) -> Bool {
        defaults?.object(forKey: refusedChangeCountKey) as? Int == changeCount
    }

    /// Whether the clipboard holds a copy history has not looked at yet.
    static func hasUnseenCopy(
        _ pasteboard: ClipboardReading,
        defaults: UserDefaults? = KeyboardPreferences.defaults
    ) -> Bool {
        pasteboard.hasStrings
            && defaults?.object(forKey: capturedChangeCountKey) as? Int != pasteboard.changeCount
    }

    /// Reads the clipboard into the history if it changed since the last
    /// look, and returns whether it kept something.
    ///
    /// `fieldAllows` is false in a password or one-time-code field: nothing
    /// is read there at all.
    @discardableResult
    static func captureIfChanged(
        _ pasteboard: ClipboardReading,
        isEnabled: Bool,
        fieldAllows: Bool,
        store: ClipboardHistoryStore = .shared,
        retention: TimeInterval = KeyboardPreferences.clipboardRetention.interval,
        defaults: UserDefaults? = KeyboardPreferences.defaults,
        now: Date = Date()
    ) -> Bool {
        guard isEnabled, fieldAllows, hasUnseenCopy(pasteboard, defaults: defaults) else { return false }
        defaults?.set(pasteboard.changeCount, forKey: capturedChangeCountKey)
        guard ClipboardHistoryPolicy.mayKeep(types: pasteboard.firstItemTypes),
              let payload = pasteboard.plainTextData(),
              let text = ClipboardHistoryPolicy.text(from: payload.data, type: payload.type)
        else { return false }
        return keep(text, isEnabled: true, fieldAllows: true, store: store, retention: retention, now: now)
    }

    /// Text that is already in hand: handed over by the Paste button, or
    /// copied by this keyboard. `types` are checked when the caller has them.
    ///
    /// `changeCount` is marked as seen whatever happens to the text. A copy
    /// refused here — pasted into a password field, or marked secret — must
    /// not be picked up later by ``captureIfChanged`` in an ordinary field,
    /// which is exactly what a password copied from Notes and pasted into a
    /// login used to become.
    @discardableResult
    static func keep(
        _ text: String,
        types: [String] = [],
        changeCount: Int? = nil,
        isEnabled: Bool,
        fieldAllows: Bool,
        store: ClipboardHistoryStore = .shared,
        retention: TimeInterval = KeyboardPreferences.clipboardRetention.interval,
        defaults: UserDefaults? = KeyboardPreferences.defaults,
        now: Date = Date()
    ) -> Bool {
        if let changeCount {
            markSeen(changeCount, defaults: defaults)
            // A copy once refused stays refused, wherever it is pasted next.
            if isRefused(changeCount, defaults: defaults) { return false }
            if !fieldAllows || !ClipboardHistoryPolicy.mayKeep(types: types) {
                markRefused(changeCount, defaults: defaults)
            }
        }
        guard isEnabled, fieldAllows,
              ClipboardHistoryPolicy.mayKeep(types: types),
              ClipboardHistoryPolicy.mayKeep(text: text)
        else { return false }
        store.update(retention: retention, now: now) { $0.add(text, at: now) }
        return true
    }

    /// The keyboard is in a password, one-time-code or card field: whatever
    /// the clipboard holds now is never kept. Called as such a field arrives
    /// and again as it goes, so a copy made while it had the keyboard —
    /// usually the very secret being typed — is never read into the history.
    /// Reads only `changeCount`, which says nothing about the content.
    static func noteSecretField(
        _ pasteboard: ClipboardReading,
        defaults: UserDefaults? = KeyboardPreferences.defaults
    ) {
        markSeen(pasteboard.changeCount, defaults: defaults)
        markRefused(pasteboard.changeCount, defaults: defaults)
    }

    private static func markRefused(_ changeCount: Int, defaults: UserDefaults?) {
        guard !isRefused(changeCount, defaults: defaults) else { return }
        defaults?.set(changeCount, forKey: refusedChangeCountKey)
    }

    private static func markSeen(_ changeCount: Int, defaults: UserDefaults?) {
        guard defaults?.object(forKey: capturedChangeCountKey) as? Int != changeCount else { return }
        defaults?.set(changeCount, forKey: capturedChangeCountKey)
    }
}
