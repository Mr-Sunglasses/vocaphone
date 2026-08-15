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
        case .recording:
            SemanticPalette.value(.recording, isDark: isDark)
        case .working:
            SemanticPalette.value(.warning, isDark: isDark)
        case .error:
            SemanticPalette.value(.error, isDark: isDark)
        case .locked:
            SemanticPalette.value(.disabled, isDark: isDark)
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
        ContrastMath.legibleLabel(on: drawnFill(for: accent, enabled: enabled))
    }

    /// The fill as the user actually sees it. A disabled primary draws its accent
    /// at ``disabledFillAlpha`` over the bar, and that composite — not the colour
    /// as declared — is what a label has to be legible on.
    func drawnFill(for accent: DictationAccent, enabled: Bool = true) -> UIColor {
        let fill = tint(for: accent)
        guard !enabled else { return fill }
        return fill
            .withAlphaComponent(Self.disabledFillAlpha)
            .compositedOver(barBackground)
    }

    /// The bar sits on the keyboard, not on the app's warm canvas, so it stays
    /// in the keys' neutral family — one step brighter than the surrounding
    /// background so it reads as a surface above them.
    var barBackground: UIColor {
        isDark ? UIColor(white: 0.145, alpha: 1) : UIColor(white: 0.988, alpha: 1)
    }

    /// Chips sit on the bar, which is itself a surface above the keys, so a
    /// 4%-alpha wash disappeared into it. These are the values a suggestion has
    /// to clear to look like something tappable rather than a stain.
    var chipBackground: UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.16)
            : UIColor.black.withAlphaComponent(0.07)
    }

    /// The hairline that gives a quiet chip an edge. Stronger than
    /// ``cardBorder``, because it has to survive being drawn over a fill that is
    /// itself only a few percent away from the bar behind it.
    var chipBorder: UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.14)
            : UIColor.black.withAlphaComponent(0.10)
    }

    var secondaryControl: UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.13)
            : UIColor.black.withAlphaComponent(0.06)
    }
}

/// Geometry for one rendering of the bar. Everything scales with the traits so
/// landscape and iPad stop inheriting portrait iPhone sizing.
struct DictationBarMetrics: Equatable {
    /// The one-row idle bar: candidates or pickers, and a round Dictate button.
    ///
    /// Smaller than ``collapsedHeight`` on purpose. Today's collapsed bar plus
    /// the grid already comes to the height of a *system* keyboard that has a
    /// suggestion strip — while having none. Adding a third region would have
    /// covered appreciably more of the host app than the keyboard vocaphone
    /// competes with, so the idle bar shrank into the strip instead and the
    /// keyboard as a whole got shorter.
    var stripHeight: CGFloat
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

    func height(for layout: DictationBarLayout, expanded: Bool) -> CGFloat {
        switch layout {
        case .strip: stripHeight
        case .status: height(expanded: expanded)
        }
    }

    /// Chips and the round Dictate button are the only content of the strip, so
    /// they take the whole row less its insets — and they must stay a
    /// comfortable touch target while doing it.
    var chipHeight: CGFloat { max(38, stripHeight - 2 * verticalInset) }

    /// Scales the portrait bar with the chosen key height, so the bar and the
    /// grid stay one composition rather than a fixed strip above keys that
    /// changed size underneath it.
    ///
    /// Modestly, though: the bar carries a title, a body and an action column
    /// whose legibility does not follow key ergonomics, so it moves by a few
    /// points where the keys move by ten.
    private func scaled(by factor: CGFloat) -> DictationBarMetrics {
        guard factor != 1 else { return self }
        var scaled = self
        scaled.stripHeight = (stripHeight * factor).rounded()
        scaled.collapsedHeight = (collapsedHeight * factor).rounded()
        scaled.expandedHeight = (expandedHeight * factor).rounded()
        scaled.primaryHeight = (primaryHeight * factor).rounded()
        scaled.controlHeight = (controlHeight * factor).rounded()
        scaled.waveformHeight = (waveformHeight * factor).rounded()
        scaled.secondaryDiameter = (secondaryDiameter * factor).rounded()
        scaled.cornerRadius = min(24, max(20, (cornerRadius * factor).rounded()))
        return scaled
    }

    static func resolved(
        for traits: UITraitCollection,
        preference: KeyboardHeightPreference
    ) -> DictationBarMetrics {
        let base = resolved(for: traits)
        // Landscape and regular-width canvases keep their dedicated metrics: one
        // has no height to give away and the other was never sized from the
        // portrait preference in the first place.
        guard traits.verticalSizeClass == .regular,
              traits.horizontalSizeClass != .regular
        else { return base }
        return switch preference {
        case .compact: base.scaled(by: 0.94)
        case .standard: base
        case .tall: base.scaled(by: 1.06)
        }
    }

    static func resolved(for traits: UITraitCollection) -> DictationBarMetrics {
        if traits.horizontalSizeClass == .regular, traits.verticalSizeClass == .regular {
            return DictationBarMetrics(
                stripHeight: 62,
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
                stripHeight: 46,
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
            stripHeight: 54,
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
