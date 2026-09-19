import SwiftUI

/// Cut-out tutorial hand for Enable keyboard.
///
/// Motion is a short reach toward the vocaphone row. Reduce Motion keeps the
/// rest pose so the name it is pointing at stays readable.
struct OnboardingPointingFinger: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let finger = Image("OnboardingPointingFinger")
            .resizable()
            .scaledToFit()
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)

        if reduceMotion {
            finger
        } else {
            finger
                .phaseAnimator([false, true]) { view, reaching in
                    view.offset(
                        x: reaching ? -10 : 0,
                        y: reaching ? -8 : 2
                    )
                } animation: { _ in
                    .easeInOut(duration: 0.95)
                }
        }
    }
}
