#if DEBUG
import SwiftUI
import UIKit

/// Puts one of the keyboard's UIKit views in an Xcode canvas.
///
/// Every surface in this extension is a `UIView`, and until now the only way to
/// look at any of them was to build the extension, install the keyboard, grant
/// Full Access, switch to it in another app, and then type the exact thing that
/// produces the state. That is why the strip, the emoji panel and half the
/// dictation bar's states had never been seen anywhere but a default-size,
/// left-to-right, English simulator.
///
/// Interaction stays on: these are the real views, so a chip really is tappable
/// in the canvas — it simply has no text document to act on.
struct KeyboardViewPreview<V: UIView>: UIViewRepresentable {
    let make: () -> V
    var configure: (V) -> Void = { _ in }

    func makeUIView(context: Context) -> V { make() }

    func updateUIView(_ view: V, context: Context) { configure(view) }
}

/// The palette and metrics the extension resolves at runtime, so a preview is
/// sized and coloured the way the keyboard will be rather than the way a canvas
/// would default to.
///
/// `@MainActor`: on newer SDKs, `UITraitCollection`'s builder closure mutates
/// `verticalSizeClass`, which UIKit now annotates as main-actor-only. Every
/// real caller here is already on the main actor — a `View` body or a
/// `UIViewRepresentable` method — so this just makes that explicit rather than
/// implicit, which is what the stricter SDK requires.
@MainActor
enum KeyboardPreviewEnvironment {
    static var traits: UITraitCollection {
        UITraitCollection { $0.verticalSizeClass = .regular }
    }

    static func palette(dark: Bool) -> KeyboardPalette { KeyboardPalette(isDark: dark) }

    static func gridMetrics(
        _ preference: KeyboardHeightPreference = .standard
    ) -> KeyboardMetrics {
        KeyboardMetrics.resolved(for: traits, preference: preference)
    }

    static func barMetrics(
        _ preference: KeyboardHeightPreference = .standard
    ) -> DictationBarMetrics {
        DictationBarMetrics.resolved(for: traits, preference: preference)
    }

    /// Recognisable words rather than plausible corrections: a preview must
    /// never look like it is proposing to change text nobody typed.
    static let candidates = [
        TypingCandidate(text: "keyboard", kind: .completion),
        TypingCandidate(text: "keeping", kind: .completion),
        TypingCandidate(text: "kept", kind: .completion),
    ]
}
#endif
