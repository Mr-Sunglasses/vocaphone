import UIKit

/// Every buzz and click the keyboard makes, in one place.
///
/// The keyboard used to ask for feedback at each call site, and got almost none
/// of it:
///
/// * A key press called `UIDevice.playInputClick()`, which is the keyboard
///   *click sound* and has never produced a haptic. Typing — the one gesture
///   that happens hundreds of times a minute — was therefore the only
///   interaction with no feedback at all.
/// * Everywhere else built a `UIFeedbackGenerator` and fired it in the same
///   statement. A generator that has not been prepared has to wake the Taptic
///   Engine first, so the first tap produces nothing and the ones after it
///   arrive late — which reads as "the haptics are broken", because from the
///   user's side they are.
///
/// So the generators live as long as the keyboard does, are prepared before
/// they are needed, and are re-prepared after each event while a burst of
/// typing keeps them warm.
///
/// Haptics also need Full Access: an extension without it cannot reach the
/// engine, and firing into that is how a preference ends up looking like a lie.
/// The click *sound* does not, so it is gated on the preference alone.
@MainActor
final class KeyboardHaptics {
    static let shared = KeyboardHaptics()

    /// Whether the extension can reach the Taptic Engine at all. Only the
    /// controller knows, so it sets this on load and on every appearance —
    /// Full Access can be revoked from Settings while the instance lives on.
    var hasFullAccess = false

    /// Split out so the rule can be checked without a Taptic Engine. Both halves
    /// matter: the preference is the user's answer and Full Access is the
    /// platform's, and neither substitutes for the other.
    static func allowsHaptics(preferenceEnabled: Bool, hasFullAccess: Bool) -> Bool {
        preferenceEnabled && hasFullAccess
    }

    /// The keyboard's own view. Generators created against a view resolve the
    /// right display, which an extension cannot be assumed to infer on its own.
    private weak var host: UIView?
    private var keyTapGenerator: UIImpactFeedbackGenerator?
    private var actionGenerator: UIImpactFeedbackGenerator?
    private var selectionGenerator: UISelectionFeedbackGenerator?

    private init() {}

    private var allowsHaptics: Bool {
        Self.allowsHaptics(
            preferenceEnabled: KeyboardPreferences.keyboardHapticsEnabled,
            hasFullAccess: hasFullAccess
        )
    }

    // MARK: - Lifecycle

    /// Binds the generators to the keyboard's view and warms them.
    ///
    /// Called on load and on each appearance, because iOS reuses extension
    /// instances across host apps: the view survives, but the engine does not
    /// stay awake between two visits to the keyboard.
    func attach(to view: UIView, hasFullAccess: Bool) {
        self.hasFullAccess = hasFullAccess
        if host !== view {
            host = view
            // Generators hold on to the view they were made for, so a new host
            // means new generators rather than stale ones aimed at a dead view.
            keyTapGenerator = nil
            actionGenerator = nil
            selectionGenerator = nil
        }
        warmUp()
    }

    /// Wakes the engine so the *next* event lands immediately. Cheap, and a
    /// no-op when the keyboard cannot use haptics anyway.
    func warmUp() {
        guard allowsHaptics else { return }
        impact(&keyTapGenerator, style: .light).prepare()
        selection().prepare()
    }

    /// Lets the engine go back to sleep. Called when the keyboard leaves the
    /// screen: a prepared generator keeps the Taptic Engine powered for a couple
    /// of seconds, which is not something a dismissed keyboard should pay for.
    func release() {
        keyTapGenerator = nil
        actionGenerator = nil
        selectionGenerator = nil
    }

    // MARK: - Events

    /// A character, space or return. The click sound and the tap together, which
    /// is what the system keyboard does.
    ///
    /// `intensity` is a little under full: a key is the most repeated event on
    /// the keyboard, and one at full strength turns a sentence into a rattle.
    func keyPress() {
        guard KeyboardPreferences.keyboardHapticsEnabled else { return }
        // Sound needs no Full Access, so it stays available to keyboards that
        // have not granted it.
        UIDevice.current.playInputClick()
        guard allowsHaptics else { return }
        let generator = impact(&keyTapGenerator, style: .light)
        generator.impactOccurred(intensity: 0.7)
        // Prepared again immediately: a typist's next key is milliseconds away,
        // and this is what keeps the engine warm through a burst.
        generator.prepare()
    }

    /// Moving between accent options, entering cursor control, opening the emoji
    /// panel: the user is choosing rather than committing.
    func selectionChanged() {
        guard allowsHaptics else { return }
        let generator = selection()
        generator.selectionChanged()
        generator.prepare()
    }

    /// A bar button — start, insert, cancel. Weightier than a key because it is
    /// rare and consequential.
    func action() {
        guard allowsHaptics else { return }
        let generator = impact(&actionGenerator, style: .soft)
        generator.impactOccurred()
        generator.prepare()
    }

    /// The moment a slide becomes a swipe. Light, because the gesture is still
    /// in flight — this says "I am tracing now", not "I typed something".
    func swipeBegan() {
        guard allowsHaptics else { return }
        let generator = impact(&keyTapGenerator, style: .light)
        generator.impactOccurred(intensity: 0.45)
        generator.prepare()
    }

    /// A traced word has been committed. Firmer than the start: a whole word
    /// just landed, and the user's eyes are on the strip rather than the keys.
    func swipeCommitted() {
        guard allowsHaptics else { return }
        let generator = impact(&actionGenerator, style: .soft)
        generator.impactOccurred(intensity: 0.8)
        generator.prepare()
    }

    // MARK: - Generators

    /// The stored generator for a role, made on first use and kept afterwards.
    private func impact(
        _ generator: inout UIImpactFeedbackGenerator?,
        style: UIImpactFeedbackGenerator.FeedbackStyle
    ) -> UIImpactFeedbackGenerator {
        if let generator { return generator }
        let created = Self.makeImpact(style: style, view: host)
        generator = created
        return created
    }

    private func selection() -> UISelectionFeedbackGenerator {
        if let selectionGenerator { return selectionGenerator }
        let created = Self.makeSelection(view: host)
        selectionGenerator = created
        return created
    }

    private static func makeImpact(
        style: UIImpactFeedbackGenerator.FeedbackStyle,
        view: UIView?
    ) -> UIImpactFeedbackGenerator {
        if #available(iOS 17.5, *), let view {
            return UIImpactFeedbackGenerator(style: style, view: view)
        }
        return UIImpactFeedbackGenerator(style: style)
    }

    private static func makeSelection(view: UIView?) -> UISelectionFeedbackGenerator {
        if #available(iOS 17.5, *), let view {
            return UISelectionFeedbackGenerator(view: view)
        }
        return UISelectionFeedbackGenerator()
    }
}
