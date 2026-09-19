import UIKit

/// Records every touch the keyboard is handed, whatever the hit test then does
/// with it.
///
/// A gesture recognizer is attached to a view, not to a hit-test result: UIKit
/// offers it every touch inside that view's hierarchy before deciding which
/// view owns it, and it keeps seeing them even when the owner discards them.
/// That makes it the one instrument that can separate the two explanations for
/// a letter that never appeared:
///
/// - The keyboard was given the touch and lost it. Something in this keyboard's
///   own routing is at fault, and reverting that routing would fix it.
/// - The keyboard was never given a touch at all. iOS discarded the contact
///   before any view saw it, and no arrangement of views can recover it — only
///   correcting the word afterwards can.
///
/// Those have opposite fixes, which is why guessing between them is not good
/// enough.
///
/// One of these on the keyboard's own view answers the first question. A second
/// on the *window* answers the one behind it: a recognizer attached to a window
/// is offered every touch in that window, whichever view ends up owning it. If
/// the window sees a touch the view never does, the touch is arriving and being
/// routed away from the keys; if neither sees it, it is not arriving at all.
///
/// Deliberately inert: it fails the moment it sees anything, does not delay
/// touches, and does not cancel them, so the keyboard behaves exactly as it
/// would without it.
final class TouchWitness: UIGestureRecognizer {
    /// Which view this one is watching, so two of them can be told apart in the
    /// trace.
    private let label: String

    init(label: String) {
        self.label = label
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // What the *event* carries, not only what was handed to us.
        //
        // Every instrument so far can see a touch only once the system has
        // decided it belongs to this keyboard. `allTouches` is the one place a
        // contact shows up that was delivered somewhere else, or that exists in
        // a phase nobody routed — which is the last remaining explanation for a
        // press that leaves no trace anywhere in this process.
        if let all = event.allTouches, all.count != touches.count {
            let phases = all
                .map { "\(TouchTrace.name($0)):\($0.phase.rawValue)" }
                .sorted()
                .joined(separator: " ")
            TouchTrace.note("event carries \(all.count) touches — \(phases)")
        }
        for touch in touches {
            let point = touch.location(in: view)
            TouchTrace.note(
                "witness/\(label) \(TouchTrace.name(touch)) "
                    + "(\(Int(point.x)),\(Int(point.y))) "
                    + "major=\(String(format: "%.1f", touch.majorRadius)) "
                    + "type=\(touch.type.rawValue)"
            )
        }
        state = .failed
    }
}
