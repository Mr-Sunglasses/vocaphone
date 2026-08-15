import SwiftUI
import UIKit

/// The semantic colour roles every vocaphone surface draws from.
///
/// ``BrandPalette`` says what vocaphone *is*; this says what a colour *means*.
/// The split matters because the two answer to different authorities: the accent
/// comes from approved brand material and never carries status, while recording,
/// warning, error and locked are fixed by the Voca app design standard and never
/// drift toward the brand green.
///
/// Every value here is a reference from that standard, written once so the app,
/// the keyboard and the Live Activity cannot each invent their own amber. Views
/// consume the roles; nothing outside this file spells a hex value.
///
/// Roles resolve per appearance. Most callers want the dynamic ``UIColor`` (or
/// its ``Color`` mirror); the keyboard, which follows the *host field's*
/// appearance rather than the system's, resolves eagerly through
/// ``value(_:isDark:)``.
enum SemanticPalette {
    // MARK: - Roles

    enum Role: CaseIterable {
        /// The main branded background. Warm paper in light, neutral charcoal in
        /// dark. Deliberate product moments only — a standard grouped list keeps
        /// its native background.
        case canvas
        /// Cards, sheets and panels sitting on ``canvas``.
        case surface
        /// A grouped or secondary surface, one step *down* from ``surface``.
        case recessedSurface
        case primaryText
        case secondaryText
        /// Dividers and quiet outlines.
        case border
        /// Focused or elevated outlines.
        case strongBorder
        /// The product accent: selection, focus, readiness, primary action.
        case accent
        /// Labels drawn on top of an ``accent`` fill.
        case onAccent
        /// Live capture. Never used for anything that is not recording.
        case recording
        /// Waiting, processing, and attention that is not yet a failure.
        case warning
        /// A failure.
        ///
        /// The same red as ``recording``, which is what the design standard
        /// assigns. They are never on screen together — a session is capturing
        /// or it has failed — and they are told apart by the title, the symbol
        /// and which actions are available, not by hue. Two nearly-identical
        /// reds would be worse than one: it would imply a distinction the
        /// reader cannot reliably see.
        case error
        /// Unavailable, locked, or not-yet-permitted. Neutral on purpose: a
        /// locked control is not an error, and colouring it red says it is.
        case disabled
    }

    // MARK: - Reference values

    /// Light appearance. `#F4F1E8` and friends, straight from the standard.
    private static func light(_ role: Role) -> UIColor {
        switch role {
        case .canvas: hex(0xF4_F1_E8)
        case .surface: hex(0xFF_FD_F7)
        case .recessedSurface: hex(0xEB_E5_D8)
        case .primaryText: hex(0x14_23_1C)
        // Two shades darker than the standard's `#68726C` reference. That
        // value lands at 3.97:1 on the recessed surface, and supporting copy in
        // this app is body-sized — so the standard's own contrast rule, which
        // outranks its reference swatch, asks for this instead.
        case .secondaryText: hex(0x5C_66_60)
        case .border: hex(0xC9_C8_BD)
        case .strongBorder: hex(0x9E_A5_9F)
        case .accent: BrandPalette.light
        case .onAccent: .white
        case .recording: hex(0xC7_3D_38)
        case .warning: hex(0xA8_61_08)
        case .error: hex(0xC7_3D_38)
        case .disabled: hex(0x8B_90_8B)
        }
    }

    /// Dark appearance. Neutral charcoal, never a saturated blue-black.
    private static func dark(_ role: Role) -> UIColor {
        switch role {
        case .canvas: hex(0x21_21_21)
        case .surface: hex(0x2A_2A_2A)
        case .recessedSurface: hex(0x30_30_30)
        case .primaryText: hex(0xF4_F1_E8)
        case .secondaryText: hex(0xAE_B5_B0)
        case .border: hex(0x3A_3A_3A)
        case .strongBorder: hex(0x55_55_55)
        case .accent: BrandPalette.dark
        case .onAccent: BrandPalette.ink
        case .recording: hex(0xFF_73_6D)
        case .warning: hex(0xF0_B3_5A)
        case .error: hex(0xFF_73_6D)
        case .disabled: hex(0x7E_83_80)
        }
    }

    // MARK: - Resolution

    /// The value for one appearance, resolved eagerly.
    ///
    /// The keyboard needs this: a dark text field inside a light app asks for a
    /// dark keyboard, and a dynamic `UIColor` tied to the trait collection
    /// cannot express that.
    static func value(_ role: Role, isDark: Bool) -> UIColor {
        isDark ? dark(role) : light(role)
    }

    /// The dynamic colour, for everything that simply follows iOS appearance.
    static func color(_ role: Role) -> UIColor {
        UIColor { traits in value(role, isDark: traits.userInterfaceStyle == .dark) }
    }

    private static func hex(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// The branded background for deliberate product moments — onboarding, the
    /// recording guide, a major empty state. Ordinary forms keep their native
    /// grouped background, which integrates better with iOS than a paper tint.
    static let vocaCanvas = Color(SemanticPalette.color(.canvas))
    static let vocaSurface = Color(SemanticPalette.color(.surface))
    static let vocaRecessedSurface = Color(SemanticPalette.color(.recessedSurface))
    static let vocaPrimaryText = Color(SemanticPalette.color(.primaryText))
    static let vocaSecondaryText = Color(SemanticPalette.color(.secondaryText))
    static let vocaBorder = Color(SemanticPalette.color(.border))
    static let vocaStrongBorder = Color(SemanticPalette.color(.strongBorder))
    /// Live capture, and nothing else.
    static let vocaRecording = Color(SemanticPalette.color(.recording))
    static let vocaWarning = Color(SemanticPalette.color(.warning))
    static let vocaError = Color(SemanticPalette.color(.error))
    static let vocaDisabled = Color(SemanticPalette.color(.disabled))
}

// MARK: - Contrast

/// WCAG contrast, computed on colours *as drawn*.
///
/// Alpha compositing is part of the question, not a detail to ignore: a fill at
/// 55% over a bar is what the reader actually sees, and judging the declared
/// colour instead is how a disabled label ends up at 2.5:1.
enum ContrastMath {
    /// The contrast ratio between two opaque colours, 1:1 to 21:1.
    static func ratio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Whichever of near-black or white is more legible on `fill`.
    ///
    /// Comparing both candidates rather than thresholding a luminance is
    /// deliberate: an earlier version thresholded the *gamma-encoded* channels
    /// and chose the worse label for three of six dark accents.
    static func legibleLabel(on fill: UIColor) -> UIColor {
        ratio(fill, ink) >= ratio(fill, .white) ? ink : .white
    }

    /// The near-black used for labels on light fills. Not pure black: on a
    /// mid-tone accent it reads as a hole rather than as text.
    static let ink = UIColor(white: 0.08, alpha: 1)

    /// WCAG relative luminance, which is defined on *linear* channels.
    static func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

extension UIColor {
    /// Flattens a translucent colour onto an opaque one, so a disabled fill can
    /// be judged as the user sees it rather than as it was declared.
    func compositedOver(_ background: UIColor) -> UIColor {
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
