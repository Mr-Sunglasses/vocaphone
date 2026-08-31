import Testing
import UIKit

/// The palette carries product claims, not just taste: an amber that has drifted
/// into the recording red says a wait is a capture, and a brand green that has
/// moved says this is a different product.
@MainActor
struct SemanticPaletteTests {
    private func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
        ContrastMath.ratio(first, second)
    }

    /// The approved brand values, pinned. `assets/generate.py` builds the icon
    /// from the same two numbers and the gateway WebUI uses them for its accent,
    /// so a change here is a change to the product's identity everywhere.
    @Test func theBrandAccentIsTheApprovedValue() {
        func hex(_ color: UIColor) -> String {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            _ = color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return String(
                format: "#%02X%02X%02X",
                Int((red * 255).rounded()),
                Int((green * 255).rounded()),
                Int((blue * 255).rounded())
            )
        }

        #expect(hex(SemanticPalette.value(.accent, isDark: false)) == "#0F6B57")
        #expect(hex(SemanticPalette.value(.accent, isDark: true)) == "#77D0B2")
        #expect(hex(SemanticPalette.value(.onAccent, isDark: true)) == "#003827")
        #expect(hex(SemanticPalette.value(.onAccent, isDark: false)) == "#FFFFFF")
    }

    /// Recording, warning and locked answer three different questions, and a
    /// reader has to be able to tell them apart at a glance.
    ///
    /// Error is deliberately not in that list: the design standard assigns one
    /// red to both live recording and failures. They never share a screen, and
    /// what separates them is the title, the symbol and which actions are
    /// available — see `DictationPresentationTests`, which pins that only a
    /// capture is ever drawn in the recording role.
    @Test func theStateColoursDoNotCollapseIntoEachOther() {
        let roles: [SemanticPalette.Role] = [.recording, .warning, .disabled, .accent]
        for isDark in [true, false] {
            let values = roles.map { SemanticPalette.value($0, isDark: isDark) }
            for (index, first) in values.enumerated() {
                for second in values[(index + 1)...] {
                    // Distance, not contrast: two colours of similar luminance
                    // and different hue are perfectly distinguishable, and a
                    // contrast ratio cannot say so.
                    #expect(
                        Self.distance(first, second) > 0.2,
                        """
                        \(isDark ? "dark" : "light"): two state colours are \
                        \(Self.distance(first, second)) apart
                        """
                    )
                }
            }
        }
    }

    /// One red, by design. Asserted rather than left implicit, so that a future
    /// change introducing a second nearly-identical red has to argue with a
    /// test instead of slipping through review.
    @Test func failuresAndRecordingShareTheStandardsOneRed() {
        for isDark in [true, false] {
            #expect(
                SemanticPalette.value(.error, isDark: isDark)
                    == SemanticPalette.value(.recording, isDark: isDark)
            )
        }
    }

    private static func distance(_ first: UIColor, _ second: UIColor) -> CGFloat {
        func components(_ color: UIColor) -> (CGFloat, CGFloat, CGFloat) {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            _ = color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return (red, green, blue)
        }
        let a = components(first)
        let b = components(second)
        return sqrt(
            pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2) + pow(a.2 - b.2, 2)
        )
    }

    /// Body text on the branded surfaces, in both appearances. Warm paper and
    /// neutral charcoal are easy to get wrong in exactly one of the two.
    @Test func textClearsAAOnEveryBrandedSurface() {
        for isDark in [true, false] {
            for surface in [
                SemanticPalette.Role.canvas, .surface, .recessedSurface,
            ] {
                let background = SemanticPalette.value(surface, isDark: isDark)
                let primary = SemanticPalette.value(.primaryText, isDark: isDark)
                let secondary = SemanticPalette.value(.secondaryText, isDark: isDark)
                #expect(
                    contrast(background, primary) >= 4.5,
                    """
                    \(isDark ? "dark" : "light") \(surface): primary text is \
                    \(contrast(background, primary)):1
                    """
                )
                #expect(
                    contrast(background, secondary) >= 4.5,
                    """
                    \(isDark ? "dark" : "light") \(surface): secondary text is \
                    \(contrast(background, secondary)):1
                    """
                )
            }
        }
    }

    /// A border that cannot be seen is not grouping anything.
    @Test func bordersRemainVisibleOnTheirOwnSurfaces() {
        for isDark in [true, false] {
            let surface = SemanticPalette.value(.surface, isDark: isDark)
            #expect(contrast(surface, SemanticPalette.value(.border, isDark: isDark)) >= 1.2)
            #expect(
                contrast(surface, SemanticPalette.value(.strongBorder, isDark: isDark))
                    > contrast(surface, SemanticPalette.value(.border, isDark: isDark))
            )
        }
    }

    /// The dark palette is neutral charcoal, not blue-black. Measured rather
    /// than asserted in a comment, because that drift happens one hex at a time.
    @Test func theDarkPaletteIsNeutralNotBlueBlack() {
        for role in [
            SemanticPalette.Role.canvas, .surface, .recessedSurface, .border, .strongBorder,
        ] {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            _ = SemanticPalette.value(role, isDark: true)
                .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            #expect(abs(blue - red) < 0.02, "\(role) leans \(blue - red) toward blue")
            #expect(abs(green - red) < 0.02)
        }
    }

    // MARK: - Keyboard

    /// iOS 26 unifies character and function fills. Earlier systems retain the
    /// stepped palette their native keyboard used.
    @Test func keyFillHierarchyMatchesTheRunningSystem() {
        for isDark in [true, false] {
            let palette = KeyboardPalette(isDark: isDark)
            let standard = ContrastMath.relativeLuminance(palette.standardKey)
            let function = ContrastMath.relativeLuminance(palette.functionKey)
            let background = ContrastMath.relativeLuminance(palette.background)
            if #available(iOS 26.0, *) {
                #expect(standard == function)
                #expect(standard > background)
            } else {
                #expect(standard > function)
                #expect(isDark ? function > background : function < background)
            }
        }
    }

    @Test func ios26KeyboardSurfacesMatchMeasuredSystemPixels() {
        guard #available(iOS 26.0, *) else { return }
        #expect(Self.rgb(KeyboardPalette(isDark: false).background) == (226, 228, 232))
        #expect(Self.rgb(KeyboardPalette(isDark: false).standardKey) == (255, 255, 255))
        #expect(Self.rgb(KeyboardPalette(isDark: true).background) == (23, 23, 23))
        #expect(Self.rgb(KeyboardPalette(isDark: true).standardKey) == (61, 61, 61))
    }

    @Test func engagedShiftUsesTheNativeNeutralSurface() {
        let palette = KeyboardPalette(isDark: false)
        let metrics = KeyboardMetrics.resolved(
            for: UITraitCollection { $0.verticalSizeClass = .regular }
        )
        let shift = KeyView(
            spec: KeySpec(cap: .shift, width: .fill, style: .function),
            metrics: metrics,
            palette: palette
        )
        shift.update(metrics: metrics, palette: palette, shift: .on, returnTitle: "return")
        #expect(shift.backgroundColor == palette.functionKey)
    }

    private static func rgb(_ color: UIColor) -> (Int, Int, Int) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        _ = color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    /// Every key label, on every fill it can be drawn on, including the pressed
    /// variants. The accent fill is the one that used to carry a hardcoded white
    /// label at roughly 1.7:1 in dark mode.
    @Test func everyKeyLabelIsLegibleOnEveryKeyFill() {
        for isDark in [true, false] {
            let palette = KeyboardPalette(isDark: isDark)
            for style in [KeyStyle.standard, .function, .accent] {
                for fill in [
                    palette.background(for: style), palette.pressedBackground(for: style),
                ] {
                    let measured = contrast(fill, palette.foreground(for: style))
                    #expect(
                        measured >= 4.5,
                        "\(isDark ? "dark" : "light") \(style) key label is \(measured):1"
                    )
                }
            }
        }
    }

    /// A press has to read as a change even where no preview is shown — on a
    /// function key, or at a height where previews are suppressed.
    @Test func aPressedKeyIsVisiblyDifferentFromAnUnpressedOne() {
        for isDark in [true, false] {
            let palette = KeyboardPalette(isDark: isDark)
            for style in [KeyStyle.standard, .function, .accent] {
                #expect(
                    palette.pressedBackground(for: style) != palette.background(for: style)
                )
            }
        }
    }

    /// Nothing branded may fall back to a system blue, which is where this
    /// product's identity used to leak away one control at a time.
    ///
    /// Compared as colours rather than as luminances. A contrast ratio cannot
    /// answer "is this blue?": hue does not enter into it, and a neutral grey
    /// can sit at the same relative luminance as a saturated blue. The disabled
    /// grey and dark-appearance `systemBlue` do exactly that, at 1.005:1 — so
    /// the ratio this test used to assert failed on a palette that is not
    /// remotely blue, and only on machines whose trait environment resolved
    /// `systemBlue` dark.
    ///
    /// `systemBlue` is also resolved for both appearances explicitly. It is a
    /// dynamic colour, and leaving it to whatever traits the test process
    /// happens to have is what made this pass locally and fail in CI.
    @Test func noKeyboardSurfaceFallsBackToSystemBlue() {
        let blues = [UIUserInterfaceStyle.light, .dark].map {
            UIColor.systemBlue.resolvedColor(with: UITraitCollection(userInterfaceStyle: $0))
        }
        for isDark in [true, false] {
            let palette = KeyboardPalette(isDark: isDark)
            let brand = BrandPalette.accent(isDark: isDark)
            #expect(palette.background(for: .accent) == brand)
            for accent in [
                DictationAccent.brand, .recording, .working, .ready, .error, .locked,
            ] {
                for blue in blues {
                    // Same measure the state colours use. The closest any
                    // accent gets is 0.61 away, so nothing here is a near miss.
                    #expect(Self.distance(palette.color(for: accent), blue) > 0.25)
                }
            }
        }
    }
}
