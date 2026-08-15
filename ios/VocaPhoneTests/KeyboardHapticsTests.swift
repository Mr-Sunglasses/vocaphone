import Testing
import UIKit

/// Whether the keyboard is allowed to buzz is a rule with two owners, and both
/// halves of it have been wrong in shipped builds: the preference was read and
/// the platform's answer was not, so a keyboard without Full Access fired into
/// an engine it could not reach and looked broken to the person who had turned
/// the setting on.
@MainActor
struct KeyboardHapticsTests {
    @Test func hapticsNeedBothThePreferenceAndFullAccess() {
        #expect(KeyboardHaptics.allowsHaptics(preferenceEnabled: true, hasFullAccess: true))
        #expect(!KeyboardHaptics.allowsHaptics(preferenceEnabled: false, hasFullAccess: true))
        // The setting is on and the platform says no. This is the case the
        // Keyboard settings screen explains rather than leaving silent.
        #expect(!KeyboardHaptics.allowsHaptics(preferenceEnabled: true, hasFullAccess: false))
        #expect(!KeyboardHaptics.allowsHaptics(preferenceEnabled: false, hasFullAccess: false))
    }

    /// Full Access can be revoked in Settings while an extension instance lives
    /// on, so the answer is re-asked on every appearance rather than cached at
    /// load.
    @Test func attachingUpdatesTheAccessTheKeyboardWasGiven() {
        let view = UIView()
        let haptics = KeyboardHaptics.shared
        haptics.attach(to: view, hasFullAccess: true)
        #expect(haptics.hasFullAccess)
        haptics.attach(to: view, hasFullAccess: false)
        #expect(!haptics.hasFullAccess)
        haptics.release()
    }

    /// Every event has to be safe to call with no engine behind it: the tests,
    /// the simulator and a keyboard without Full Access all run this path.
    @Test func everyEventIsSafeWithoutAnEngine() {
        let haptics = KeyboardHaptics.shared
        haptics.attach(to: UIView(), hasFullAccess: false)
        haptics.keyPress()
        haptics.selectionChanged()
        haptics.action()
        haptics.swipeBegan()
        haptics.swipeCommitted()
        haptics.warmUp()
        haptics.release()
    }
}
