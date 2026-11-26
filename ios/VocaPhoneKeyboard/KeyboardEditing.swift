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

/// Something this keyboard did to the document that Undo can take back.
enum KeyboardEdit: Equatable, Sendable {
    /// Text the keyboard put in at the cursor: a paste, a clip, a dictation.
    /// `following` is the document after the cursor when it went in.
    case inserted(text: String, following: String?, documentID: String?)
    /// Text the keyboard cut. `before` and `after` are the windows either
    /// side of the cursor straight after the cut.
    case removed(text: String, before: String?, after: String?, documentID: String?)
}

enum KeyboardEditUndo {
    enum Step: Equatable {
        case deleteBackward(count: Int)
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
        case let .inserted(text, following, documentID):
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
    /// The content itself. iOS may ask the user before answering.
    var string: String? { get }
}

extension UIPasteboard: ClipboardReading {
    var firstItemTypes: [String] { types }
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
              let text = pasteboard.string
        else { return false }
        return keep(text, isEnabled: true, fieldAllows: true, store: store, retention: retention, now: now)
    }

    /// Text that is already in hand: handed over by the Paste button, or
    /// copied by this keyboard. `types` are checked when the caller has them.
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
        guard isEnabled, fieldAllows,
              ClipboardHistoryPolicy.mayKeep(types: types),
              ClipboardHistoryPolicy.mayKeep(text: text)
        else { return false }
        if let changeCount { defaults?.set(changeCount, forKey: capturedChangeCountKey) }
        store.update(retention: retention, now: now) { $0.add(text, at: now) }
        return true
    }
}
