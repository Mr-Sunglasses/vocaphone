import UIKit

/// Enabled system keyboards, globe order.
///
/// App-only. `UITextInputMode.activeInputModes` is a required-reason API
/// (`3EC4.1` in the app PrivacyInfo). `LocalModelCatalog` is compiled into the
/// keyboard and Live Activity, which must not ship that call.
enum KeyboardInputLanguages {
    /// UIKit rebuilds `activeInputModes` on every access and its order is not
    /// ours to rely on, while the recommendation list is built from the first
    /// element. Reading it inside `body` let the cards reorder on any redraw —
    /// including the progress tick of a download the user was watching.
    ///
    /// The answer genuinely changes only when the user edits their keyboards,
    /// which they can only do in Settings, so the snapshot is retaken when a
    /// screen opens and when the app comes back.
    @MainActor private static var held: [String]?

    @MainActor
    static var enabledPrimaryLanguages: [String] {
        UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
    }

    @MainActor
    static var snapshot: [String] {
        if let held { return held }
        let fresh = enabledPrimaryLanguages
        held = fresh
        return fresh
    }

    @MainActor
    static func refresh() {
        held = enabledPrimaryLanguages
    }
}
