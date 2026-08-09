import SwiftUI
import UIKit

/// The brand colours, written down once for every target that draws them.
///
/// These are the same two values `assets/generate.py` builds the icon from and
/// the gateway WebUI uses for its accent, so the app, the keyboard, the Live
/// Activity, the launcher icon and the server agree on what vocaphone looks
/// like. Before this existed the app was tinted `.systemBlue`, the keyboard's
/// resting accent was `.systemBlue`, and the icon was green — three identities
/// for one product.
///
/// Semantic colour is deliberately *not* here. Recording stays red and warnings
/// stay amber, because those mean something to the reader that a brand colour
/// would only obscure.
enum BrandPalette {
    /// `#0F6B57`, the flat icon field. Dark enough to carry white text, so it is
    /// also the filled-button colour on light surfaces.
    static let light = UIColor(red: 0x0F / 255, green: 0x6B / 255, blue: 0x57 / 255, alpha: 1)

    /// `#77D0B2`, the same role on a dark surface, where `light` fails contrast
    /// against the near-black background. It is light enough that text drawn on
    /// top of it has to be dark — see ``ink``.
    static let dark = UIColor(red: 0x77 / 255, green: 0xD0 / 255, blue: 0xB2 / 255, alpha: 1)

    /// `#003827`, for text and glyphs sitting *on* ``dark``. Same value as the
    /// Compose theme's dark `onPrimary`; `ColorPaletteTest` on Android pins it.
    static let ink = UIColor(red: 0x00 / 255, green: 0x38 / 255, blue: 0x27 / 255, alpha: 1)

    /// Resolves per appearance, which is what almost every caller wants.
    static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? dark : light
    }

    static func accent(isDark: Bool) -> UIColor { isDark ? dark : light }
}

extension BrandPalette {
    /// The label colour for anything *filled* with ``accent``.
    ///
    /// White in light mode, where the fill is the dark `#0F6B57`; near-black in
    /// dark mode, where the fill is the light `#77D0B2` and white would land at
    /// about 1.7:1.
    static let onAccent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? ink : .white
    }
}

extension Color {
    /// The app's tint. Everything that used to say `.blue` says this instead.
    static let brand = Color(BrandPalette.accent)

    /// For labels drawn on top of a brand-filled background.
    static let onBrand = Color(BrandPalette.onAccent)
}

extension View {
    /// A filled primary button.
    ///
    /// `.borderedProminent` fills with the tint and always draws a **white**
    /// label. That is fine on the light palette's `#0F6B57` and unreadable on the
    /// dark palette's `#77D0B2`, so the label colour has to be stated rather than
    /// inherited. Every prominent button in the app goes through here.
    func brandProminentButton() -> some View {
        buttonStyle(.borderedProminent)
            .foregroundStyle(Color.onBrand)
    }
}
