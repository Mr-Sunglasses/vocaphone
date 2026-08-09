import Testing
import UIKit

/// `labelColor(for:enabled:)` picks between near-black and white for a label drawn
/// on a filled control. Its first version thresholded a luminance computed from
/// *gamma-encoded* channels, which chose the worse of the two options for three of
/// the six dark accents — so the rule is worth pinning rather than trusting.
struct DictationBarLabelColorTests {

    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        _ = color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private let accents: [DictationAccent] = [
        .brand, .handoff, .listening, .working, .ready, .alert, .locked,
    ]

    @Test func everyAccentGetsTheMoreLegibleOfTheTwoLabelColours() {
        for isDark in [true, false] {
            let palette = KeyboardPalette(isDark: isDark)
            for accent in accents {
                let fill = palette.drawnFill(for: accent)
                let chosen = palette.labelColor(for: accent)
                let other: UIColor = chosen == UIColor.white
                    ? UIColor(white: 0.08, alpha: 1)
                    : .white
                #expect(
                    contrast(fill, chosen) >= contrast(fill, other),
                    """
                    \(isDark ? "dark" : "light") \(accent) fill took the worse label: \
                    \(contrast(fill, chosen)) vs \(contrast(fill, other))
                    """
                )
            }
        }
    }

    /// The floor an *enabled* accent has to clear.
    ///
    /// 3:1, not 4.5:1, because the primary's label is 14pt semibold and WCAG puts
    /// its large-text threshold at 14pt bold. The tightest fill in practice is the
    /// light-mode `.working` amber at 4.34:1, so there is real headroom — but the
    /// number asserted is the one actually required, not the one today's palette
    /// happens to reach.
    ///
    /// Disabled fills are deliberately not held to this. A disabled control is
    /// meant to recede, and WCAG exempts inactive components from the contrast
    /// minimum; what matters for them is that they take the *better* of the two
    /// labels, which the test below checks for every accent.
    @Test func everyEnabledAccentClearsTheLargeTextFloor() {
        for isDark in [true, false] {
            let palette = KeyboardPalette(isDark: isDark)
            for accent in accents {
                let fill = palette.drawnFill(for: accent)
                let measured = contrast(fill, palette.labelColor(for: accent))
                #expect(
                    measured >= 3.0,
                    "\(isDark ? "dark" : "light") \(accent) label is \(measured):1"
                )
            }
        }
    }

    /// A disabled primary draws its fill at 55% over the bar, so the label has to
    /// be chosen against that composite. Judging the opaque colour instead picked
    /// white on a light-mode fill that composites to roughly #79ACA3, at ~2.5:1.
    @Test func aDisabledFillIsJudgedAsItIsDrawn() {
        for isDark in [true, false] {
            let palette = KeyboardPalette(isDark: isDark)
            for accent in accents {
                let drawn = palette.drawnFill(for: accent, enabled: false)
                let opaque = palette.drawnFill(for: accent, enabled: true)
                #expect(drawn != opaque, "a disabled fill should differ from the enabled one")

                let chosen = palette.labelColor(for: accent, enabled: false)
                let other: UIColor = chosen == UIColor.white
                    ? UIColor(white: 0.08, alpha: 1)
                    : .white
                #expect(
                    contrast(drawn, chosen) >= contrast(drawn, other),
                    "\(isDark ? "dark" : "light") disabled \(accent) took the worse label"
                )
            }
        }
    }
}
