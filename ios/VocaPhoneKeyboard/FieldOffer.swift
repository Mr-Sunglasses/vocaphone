import UIKit

/// What the strip offers in an empty field instead of words.
///
/// - **Paste**, when something was copied in the last few minutes and has not
///   been pasted from this keyboard yet. Drawn as the system paste button
///   (`PasteButton`/`UIPasteControl`), which hands the clipboard over only on
///   the user's tap, so iOS never shows its "Allow Paste" prompt and nothing
///   reads the clipboard before then. Needs Full Access, as any clipboard does.
/// - **Code from Messages** in a one-time-code field, and **Passwords** in a
///   username or password field: iOS gives codes from Messages and saved logins
///   only to its own keyboard, so the chip switches to it.
enum FieldOffer: Equatable {
    case paste
    case oneTimeCode
    case passwords

    var title: String {
        switch self {
        case .paste: "Paste"
        case .oneTimeCode: "Code from Messages"
        case .passwords: "Passwords"
        }
    }

    /// How long a copy stays worth offering.
    static let recentCopyWindow: TimeInterval = 3 * 60

    static func decide(
        fieldIsEmpty: Bool,
        contentType: UITextContentType?,
        hasFullAccess: Bool,
        hasRecentUnpastedCopy: Bool
    ) -> FieldOffer? {
        guard fieldIsEmpty else { return nil }
        switch contentType {
        case .oneTimeCode?: return .oneTimeCode
        case .username?, .password?, .newPassword?: return .passwords
        default: break
        }
        return hasFullAccess && hasRecentUnpastedCopy ? .paste : nil
    }
}

/// Tracks copies by `UIPasteboard.changeCount`, which reveals that the
/// clipboard changed and nothing about what is on it. Kept in the App Group
/// so every keyboard instance agrees.
enum ClipboardWatch {
    private static let seenCountKey = "clipboardSeenChangeCount"
    private static let seenAtKey = "clipboardSeenAt"
    private static let pastedCountKey = "clipboardPastedChangeCount"

    /// Whether a copy was made within ``FieldOffer/recentCopyWindow`` that
    /// this keyboard has not pasted. The first time a new change count is
    /// seen counts as the moment of the copy.
    static func hasRecentUnpastedCopy(
        changeCount: Int,
        hasStrings: Bool,
        defaults: UserDefaults? = KeyboardPreferences.defaults,
        now: Date = Date()
    ) -> Bool {
        guard hasStrings, let defaults else { return false }
        if defaults.object(forKey: seenCountKey) as? Int != changeCount {
            defaults.set(changeCount, forKey: seenCountKey)
            defaults.set(now, forKey: seenAtKey)
        }
        guard defaults.object(forKey: pastedCountKey) as? Int != changeCount,
              let seenAt = defaults.object(forKey: seenAtKey) as? Date
        else { return false }
        return now.timeIntervalSince(seenAt) <= FieldOffer.recentCopyWindow
    }

    static func notePasted(changeCount: Int, defaults: UserDefaults? = KeyboardPreferences.defaults) {
        defaults?.set(changeCount, forKey: pastedCountKey)
    }
}
