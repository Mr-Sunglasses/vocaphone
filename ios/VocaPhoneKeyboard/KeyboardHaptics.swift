import UIKit

@MainActor
protocol KeyboardFeedbackProviding: AnyObject {
    func keyPressed()
    func textCommitted()
    func keyActionCommitted()
    func deleteRepeated()
    func selectionChanged()
    func action()
    func swipeBegan()
    func swipeCommitted()
}

/// The semantic feedback a keyboard interaction may produce. Keeping this as
/// data lets tests prove that a cancelled touch cannot buzz or click, without
/// pretending the simulator has a Taptic Engine.
enum KeyboardFeedbackEvent: Equatable {
    case inputClick
    case typingHaptic
    case selectionHaptic
    case actionHaptic
    case swipeBeganHaptic
    case swipeCommittedHaptic
}

enum KeyboardFeedbackInteraction {
    case keyPressed
    case committedText
    case committedKeyAction
    case deleteRepeated
    case selectionChanged
    case dictationAction
    case swipeBegan
    case swipeCommitted
}

enum KeyboardFeedbackPolicy {
    static func events(
        for interaction: KeyboardFeedbackInteraction,
        typingHapticsEnabled: Bool,
        hasFullAccess: Bool
    ) -> [KeyboardFeedbackEvent] {
        let allowsHaptics = typingHapticsEnabled && hasFullAccess
        switch interaction {
        case .keyPressed:
            // The system keyboard clicks the instant a finger lands, not when
            // it lifts. Feedback that waits for the commit arrives after the
            // key has already animated, which is what reads as "not native".
            return [.inputClick]
        case .committedText:
            // The click has already been played on touch-down. What waits for
            // the commit is the tactile confirmation, so a cancelled or
            // slid-away touch never buzzes for a character it did not insert.
            return allowsHaptics ? [.typingHaptic] : []
        case .committedKeyAction:
            // Shift, Delete, plane switching and the globe resolve on
            // touch-down, so their haptic lands with the same press that
            // already clicked.
            return allowsHaptics ? [.typingHaptic] : []
        case .deleteRepeated:
            // A held Delete is a stream of separate deletions, and the system
            // keyboard sounds each one. Silence here makes a hold feel like it
            // has stopped working.
            return [.inputClick] + (allowsHaptics ? [.typingHaptic] : [])
        case .selectionChanged:
            return allowsHaptics ? [.selectionHaptic] : []
        case .dictationAction:
            return allowsHaptics ? [.actionHaptic] : []
        case .swipeBegan:
            return allowsHaptics ? [.swipeBeganHaptic] : []
        case .swipeCommitted:
            return allowsHaptics ? [.swipeCommittedHaptic] : []
        }
    }
}

/// Every buzz and click the keyboard makes, in one place.
///
/// A standard keyboard click is audio feedback controlled by iOS Settings. It
/// is not a haptic, must not be disabled by VocaPhone's optional tactile
/// preference, and is played on touch-down because that is when the system
/// keyboard plays it. Custom haptics are deliberately opt-in and wait for the
/// interaction to commit. Typing is played at full strength on the crispest
/// style, because a key is a hard, short click and anything softer reads as
/// weaker than every other keyboard on the phone. The rarer events vary against
/// that reference rather than sitting below it.
@MainActor
final class KeyboardHaptics: KeyboardFeedbackProviding {
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
            preferenceEnabled: KeyboardPreferences.typingHapticsEnabled,
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
    ///
    /// Every generator is warmed, not just the typing one: a dictation action
    /// and a committed swipe are exactly the rare events that would otherwise
    /// pay the wake-up cost on their first use, which is the late-first-haptic
    /// problem this whole type exists to avoid.
    func warmUp() {
        guard allowsHaptics else { return }
        keyTapImpact().prepare()
        actionImpact().prepare()
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

    /// A finger has landed on a key. This is the click, and it is deliberately
    /// not deferred: the system keyboard sounds a key as it goes down, and
    /// feedback that waits for the lift arrives after the key has finished
    /// animating.
    func keyPressed() {
        perform(.keyPressed)
    }

    /// A character, space, Return, or emoji that has actually inserted. Calling
    /// this only after target resolution prevents a missed or cancelled touch
    /// from confirming the wrong key in the person's hand.
    func textCommitted() {
        perform(.committedText)
    }

    /// An immediate keyboard control such as Shift, Delete, plane switching, or
    /// the globe. Their press already clicked; this is the tactile half.
    func keyActionCommitted() {
        perform(.committedKeyAction)
    }

    /// One character removed by a held Delete, rather than by its first press.
    func deleteRepeated() {
        perform(.deleteRepeated)
    }

    /// Moving between accent options, entering cursor control, opening the emoji
    /// panel: the user is choosing rather than committing.
    func selectionChanged() {
        perform(.selectionChanged)
    }

    /// A bar button — start, insert, cancel. Weightier than a key because it is
    /// rare and consequential.
    func action() {
        perform(.dictationAction)
    }

    /// The moment a slide becomes a swipe. Lighter than a keystroke, because
    /// the gesture is still in flight — this says "I am tracing now", not
    /// "I typed something".
    func swipeBegan() {
        perform(.swipeBegan)
    }

    /// A traced word has been committed. Firmer than the start: a whole word
    /// just landed, and the user's eyes are on the strip rather than the keys.
    func swipeCommitted() {
        perform(.swipeCommitted)
    }

    private func perform(_ interaction: KeyboardFeedbackInteraction) {
        for event in KeyboardFeedbackPolicy.events(
            for: interaction,
            typingHapticsEnabled: KeyboardPreferences.typingHapticsEnabled,
            hasFullAccess: hasFullAccess
        ) {
            switch event {
            case .inputClick:
                UIDevice.current.playInputClick()
            case .typingHaptic:
                // `.rigid` rather than `.light`: a key is a hard, short click,
                // and `.light` is the softest and most diffuse of the styles —
                // it reads as a nudge where the system keyboard reads as a
                // press. Full intensity because a third of the engine's power
                // is exactly what made this feel weaker than every other
                // keyboard on the phone.
                let generator = keyTapImpact()
                generator.impactOccurred(intensity: 1)
                generator.prepare()
            case .selectionHaptic:
                let generator = selection()
                generator.selectionChanged()
                generator.prepare()
            case .actionHaptic:
                let generator = actionImpact()
                generator.impactOccurred()
                generator.prepare()
            case .swipeBeganHaptic:
                // The same instrument as a keystroke, played softer: the
                // gesture is still in flight, so it should register as related
                // to typing but plainly not a committed character.
                let generator = keyTapImpact()
                generator.impactOccurred(intensity: 0.5)
                generator.prepare()
            case .swipeCommittedHaptic:
                let generator = actionImpact()
                generator.impactOccurred(intensity: 0.8)
                generator.prepare()
            }
        }
    }

    // MARK: - Generators

    /// The keystroke generator: crisp and short, like a key.
    ///
    /// A generator's style is fixed when it is built, so each role owns its
    /// style rather than taking it as an argument. Passing one to a cached
    /// generator would have been silently ignored, leaving the keyboard playing
    /// whichever texture happened to be requested first.
    private func keyTapImpact() -> UIImpactFeedbackGenerator {
        cached(&keyTapGenerator, style: .rigid)
    }

    /// The generator for rare, weightier events: softer and more diffuse.
    private func actionImpact() -> UIImpactFeedbackGenerator {
        cached(&actionGenerator, style: .soft)
    }

    private func cached(
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
