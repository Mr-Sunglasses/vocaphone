import UIKit

/// Concrete colours for the bar, resolved eagerly for one appearance exactly as
/// the key colours are, so a dark field inside a light app still gets a dark bar.
extension KeyboardPalette {
    /// One calm, solid accent per state. The bar needs a clear action colour,
    /// not decorative colour travel.
    func color(for accent: DictationAccent) -> UIColor {
        switch accent {
        // `.brand` is the resting state and `.ready` is a finished one; they are
        // never on screen together, and both are the product saying "fine". They
        // share the brand colour rather than being two greens a shade apart --
        // the titles ("Ready to dictate", "Transcript ready") carry the
        // difference. `.brand` was `.systemBlue`, which matched nothing else the
        // product draws.
        case .brand, .ready:
            BrandPalette.accent(isDark: isDark)
        case .handoff:
            isDark ? rgb(0.64, 0.69, 0.98) : rgb(0.31, 0.36, 0.75)
        case .listening:
            isDark ? rgb(1, 0.45, 0.44) : rgb(0.82, 0.18, 0.19)
        case .working:
            isDark ? rgb(1, 0.72, 0.38) : rgb(0.72, 0.39, 0.05)
        case .alert:
            isDark ? rgb(1, 0.48, 0.43) : rgb(0.72, 0.19, 0.15)
        case .locked:
            isDark ? rgb(0.58, 0.6, 0.63) : rgb(0.43, 0.45, 0.48)
        }
    }

    /// The single colour used for stateful controls, the dot, and waveform.
    func tint(for accent: DictationAccent) -> UIColor {
        color(for: accent)
    }

    /// The alpha ``DictationPrimaryButton`` draws a disabled fill at. It lives
    /// here because ``labelColor(on:enabled:)`` has to know what the fill will
    /// actually look like, and a second copy of the number would decide wrong.
    static let disabledFillAlpha: CGFloat = 0.55

    /// The label colour a filled control can actually carry: whichever of near-
    /// black or white has more contrast against the fill *as drawn*.
    ///
    /// Every dark-appearance accent here is a light pastel, so the hardcoded
    /// white title this replaces sat at roughly 2:1 against its own fill.
    ///
    /// It compares the two candidates rather than thresholding a luminance,
    /// which is what the first version of this did — and it got three of the six
    /// dark accents wrong, because it weighted the *gamma-encoded* channels.
    /// `.listening` scored 0.566 against a 0.6 threshold and so took white, at
    /// 2.65:1, where near-black would have been 6.93:1. Relative luminance needs
    /// the channels linearised first; having done that, comparing both options
    /// is no more work than picking a cut-off and cannot be off by one accent.
    func labelColor(for accent: DictationAccent, enabled: Bool = true) -> UIColor {
        let drawn = drawnFill(for: accent, enabled: enabled)
        let ink = UIColor(white: 0.08, alpha: 1)
        return contrast(drawn, ink) >= contrast(drawn, .white) ? ink : .white
    }

    /// The fill as the user actually sees it. A disabled primary draws its accent
    /// at ``disabledFillAlpha`` over the bar, and that composite — not the colour
    /// as declared — is what a label has to be legible on.
    func drawnFill(for accent: DictationAccent, enabled: Bool = true) -> UIColor {
        let fill = tint(for: accent)
        guard !enabled else { return fill }
        return fill
            .withAlphaComponent(Self.disabledFillAlpha)
            .composited(over: barBackground)
    }

    private func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let a = first.relativeLuminance
        let b = second.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    var barBackground: UIColor {
        isDark
            ? UIColor(red: 0.135, green: 0.145, blue: 0.17, alpha: 1)
            : UIColor(red: 0.985, green: 0.99, blue: 1, alpha: 1)
    }

    var chipBackground: UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.1)
            : UIColor.black.withAlphaComponent(0.045)
    }

    var secondaryControl: UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.13)
            : UIColor.black.withAlphaComponent(0.06)
    }

    private func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}

private extension UIColor {
    /// WCAG relative luminance, which is defined on *linear* channels — sRGB
    /// components have to be un-gamma'd first, which is the step the earlier
    /// threshold-based label rule skipped.
    var relativeLuminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Flattens a translucent colour onto an opaque one, so a disabled fill can
    /// be judged as the user sees it rather than as it was declared.
    func composited(over background: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var backRed: CGFloat = 0
        var backGreen: CGFloat = 0
        var backBlue: CGFloat = 0
        var backAlpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              background.getRed(&backRed, green: &backGreen, blue: &backBlue, alpha: &backAlpha)
        else { return self }
        return UIColor(
            red: alpha * red + (1 - alpha) * backRed,
            green: alpha * green + (1 - alpha) * backGreen,
            blue: alpha * blue + (1 - alpha) * backBlue,
            alpha: 1
        )
    }
}

/// Geometry for one rendering of the bar. Everything scales with the traits so
/// landscape and iPad stop inheriting portrait iPhone sizing.
struct DictationBarMetrics: Equatable {
    var collapsedHeight: CGFloat
    var expandedHeight: CGFloat
    var horizontalInset: CGFloat
    var verticalInset: CGFloat
    var titleFontSize: CGFloat
    var bodyFontSize: CGFloat
    var controlHeight: CGFloat
    var waveformHeight: CGFloat
    var primaryWidth: CGFloat
    var primaryHeight: CGFloat
    var secondaryDiameter: CGFloat
    var cornerRadius: CGFloat
    /// A transcript preview is worth two lines where there is room for them.
    var messageLineLimit: Int

    func height(expanded: Bool) -> CGFloat {
        expanded ? expandedHeight : collapsedHeight
    }

    static func resolved(for traits: UITraitCollection) -> DictationBarMetrics {
        if traits.horizontalSizeClass == .regular, traits.verticalSizeClass == .regular {
            return DictationBarMetrics(
                collapsedHeight: 82,
                expandedHeight: 96,
                horizontalInset: 16,
                verticalInset: 12,
                titleFontSize: 17,
                bodyFontSize: 14,
                controlHeight: 34,
                waveformHeight: 40,
                primaryWidth: 138,
                primaryHeight: 50,
                secondaryDiameter: 40,
                cornerRadius: 24,
                messageLineLimit: 2
            )
        }
        if traits.verticalSizeClass == .compact {
            // Landscape phones have almost no height to spare, so the bar gives
            // up its breathing room before the keys give up theirs.
            return DictationBarMetrics(
                collapsedHeight: 58,
                expandedHeight: 58,
                horizontalInset: 11,
                verticalInset: 6,
                titleFontSize: 13,
                bodyFontSize: 11,
                controlHeight: 24,
                waveformHeight: 20,
                primaryWidth: 98,
                primaryHeight: 36,
                secondaryDiameter: 28,
                cornerRadius: 17,
                messageLineLimit: 1
            )
        }
        return DictationBarMetrics(
            collapsedHeight: 72,
            expandedHeight: 84,
            horizontalInset: 13,
            verticalInset: 9,
            titleFontSize: 15,
            bodyFontSize: 12.5,
            controlHeight: 30,
            waveformHeight: 34,
            primaryWidth: 116,
            primaryHeight: 44,
            secondaryDiameter: 34,
            cornerRadius: 21,
            messageLineLimit: 2
        )
    }
}
