import Foundation

enum AppConfiguration {
    /// Must match the `com.apple.security.application-groups` entitlement of
    /// all three targets, which is what the App Store profile is minted
    /// against. A value that only exists in this file is not a smaller mistake
    /// than a missing entitlement: the container this names is the only channel
    /// the keyboard and the app have, so drift takes dictation out entirely
    /// rather than degrading it. See ``appGroupMatchesEntitlements`` — the test
    /// that reads the entitlement files rather than trusting this line.
    static let appGroupIdentifier = "group.com.vocahq"
    /// The identifier the app ships under. Only a fallback for when the running
    /// bundle declines to name itself, which is what a unit-test host does.
    static let shippingAppBundleIdentifier = "com.vocahq.vocaphone"

    /// The keyboard extension's bundle identifier.
    ///
    /// Used to spot the keyboard in the user's enabled list, which iOS
    /// publishes as bundle identifiers under an undocumented key.
    ///
    /// Derived from the running bundle rather than written down, because a
    /// hardcoded one rots silently the moment anyone re-signs under their own
    /// identifier to test on a device. Everything else gets renamed — the
    /// targets, the entitlements, the App Group — and this does not, so guided
    /// setup scans the enabled list for an identifier no installed keyboard
    /// has, concludes the keyboard is missing, and traps onboarding on the page
    /// that will not advance until it appears. The keyboard is sitting in the
    /// list the whole time, working.
    ///
    /// The comment this replaces said drift here "degrades guided setup rather
    /// than breaking dictation". That was too kind: onboarding cannot be walked
    /// past the keyboard step, so nothing downstream of it happens either.
    static var keyboardBundleIdentifier: String {
        keyboardBundleIdentifier(forHostBundle: Bundle.main.bundleIdentifier)
    }

    /// Split out so the derivation can be checked without a bundle.
    ///
    /// `project.yml` builds the extension's identifier as the app's with
    /// `.keyboard` appended, and that relationship is the whole rule.
    static func keyboardBundleIdentifier(forHostBundle running: String?) -> String {
        let host = running ?? shippingAppBundleIdentifier
        // Asked from inside the keyboard itself, the answer is already in hand.
        if host.hasSuffix(keyboardSuffix) { return host }
        // Asked from another extension, strip its own component first so the
        // sibling is derived from the app rather than from the asker.
        if host.hasSuffix(liveActivitySuffix) {
            return String(host.dropLast(liveActivitySuffix.count)) + keyboardSuffix
        }
        return host + keyboardSuffix
    }

    private static let keyboardSuffix = ".keyboard"
    private static let liveActivitySuffix = ".liveactivity"
    static let urlScheme = "vocaphone"
    /// The manual route to the Full Access switch, written once because the app
    /// and the keyboard both have to give it and they must not disagree.
    ///
    /// iOS exposes no URL that opens this pane — `openSettingsURLString` lands
    /// in vocaphone's own settings, which does not contain the switch — so these
    /// words are the whole recovery path, and calling anything else a "deep
    /// link" to it would be a promise the system cannot keep.
    static let fullAccessSettingsPath =
        "Settings › General › Keyboard › Keyboards › vocaphone › Allow Full Access."

    /// The same instruction, front-loaded for the keyboard's two-line bar.
    ///
    /// The full path does not fit there and truncates mid-phrase — "… › Allow
    /// Full A…" — which drops the one part the reader has to act on. Naming the
    /// switch first means a truncation costs the tail of the path, which the
    /// containing app spells out in full under Privacy and permissions.
    static let fullAccessKeyboardHint =
        "Turn on Allow Full Access under Settings › General › Keyboard."
    static let maximumRecordingSeconds: TimeInterval = 120
    static let quickDictationWindowSeconds: TimeInterval = 10 * 60
    /// How long the keyboard waits for an unclaimed Quick Dictation request
    /// before falling back to opening vocaphone.
    static let quickDictationLaunchFallbackSeconds: TimeInterval = 1.5
    /// How long it keeps waiting once the containing app has claimed the
    /// request. Warming the microphone graph can take several seconds — a first
    /// on-device model load, or another app still releasing the input — and
    /// switching apps on a dictation that is about to start anyway is the more
    /// disruptive failure.
    static let quickDictationClaimedLaunchDeadlineSeconds: TimeInterval = 8
}
