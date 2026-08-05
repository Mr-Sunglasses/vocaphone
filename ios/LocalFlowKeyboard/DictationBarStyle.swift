import UIKit

/// Concrete colours for the bar, resolved eagerly for one appearance exactly as
/// the key colours are, so a dark field inside a light app still gets a dark bar.
extension KeyboardPalette {
    /// Two stops per accent. A flat fill reads as a stock system control; the
    /// slight hue travel is what makes the primary button look deliberate.
    func gradient(for accent: DictationAccent) -> [UIColor] {
        switch accent {
        case .brand:
            isDark
                ? [rgb(0.36, 0.54, 1), rgb(0.55, 0.47, 1)]
                : [rgb(0.16, 0.42, 0.96), rgb(0.42, 0.35, 0.95)]
        case .handoff:
            isDark
                ? [rgb(0.51, 0.47, 1), rgb(0.68, 0.45, 0.99)]
                : [rgb(0.35, 0.33, 0.87), rgb(0.53, 0.34, 0.93)]
        case .listening:
            isDark
                ? [rgb(1, 0.34, 0.4), rgb(1, 0.42, 0.62)]
                : [rgb(0.93, 0.2, 0.29), rgb(0.97, 0.32, 0.52)]
        case .working:
            isDark
                ? [rgb(1, 0.62, 0.24), rgb(1, 0.76, 0.29)]
                : [rgb(0.96, 0.51, 0.09), rgb(0.98, 0.68, 0.18)]
        case .ready:
            isDark
                ? [rgb(0.19, 0.82, 0.5), rgb(0.16, 0.83, 0.71)]
                : [rgb(0.09, 0.68, 0.4), rgb(0.1, 0.72, 0.6)]
        case .alert:
            isDark
                ? [rgb(1, 0.36, 0.36), rgb(1, 0.47, 0.34)]
                : [rgb(0.87, 0.19, 0.22), rgb(0.94, 0.33, 0.24)]
        case .locked:
            isDark
                ? [rgb(0.45, 0.46, 0.51), rgb(0.53, 0.54, 0.59)]
                : [rgb(0.53, 0.54, 0.58), rgb(0.61, 0.62, 0.66)]
        }
    }

    /// The single colour used for the status dot, the waveform and any accented
    /// text — the gradient's first stop, which is its most saturated end.
    func tint(for accent: DictationAccent) -> UIColor {
        gradient(for: accent)[0]
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
