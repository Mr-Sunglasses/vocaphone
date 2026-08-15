import UIKit

enum KeyPlane: Equatable {
    case letters
    case numbers
    case symbols
}

enum KeyCap: Equatable {
    /// Stores the unshifted form. Letters resolve through the current shift
    /// state; digits and punctuation ignore it.
    case character(String)
    case shift
    case delete
    case space
    case newline
    case plane(KeyPlane)
    case globe

    /// Character keys are the only ones that show a preview and accept a finger
    /// sliding in from a neighbour, matching the system keyboard.
    var isCharacter: Bool {
        if case .character = self { return true }
        return false
    }

    func resolvedText(shift: ShiftState) -> String? {
        guard case let .character(value) = self else { return nil }
        return shift == .off ? value : value.uppercased()
    }

    func accessibilityLabel(shift: ShiftState) -> String {
        switch self {
        case let .character(value):
            return Self.spokenNames[value] ?? (shift == .off ? value : value.uppercased())
        case .shift: return "Shift"
        case .delete: return "Delete"
        case .space: return "Space"
        case .newline: return "Return"
        case .globe: return "Next keyboard"
        case let .plane(plane):
            switch plane {
            case .letters: return "Letters"
            case .numbers: return "Numbers"
            case .symbols: return "Symbols"
            }
        }
    }

    private static let spokenNames: [String: String] = [
        ".": "Period", ",": "Comma", "?": "Question mark", "!": "Exclamation mark",
        "'": "Apostrophe", "\"": "Quotation mark", "-": "Hyphen", "/": "Slash",
        ":": "Colon", ";": "Semicolon", "(": "Left parenthesis", ")": "Right parenthesis",
        "$": "Dollar sign", "&": "Ampersand", "@": "At sign", "#": "Number sign",
        "%": "Percent", "^": "Caret", "*": "Asterisk", "+": "Plus", "=": "Equals",
        "_": "Underscore", "\\": "Backslash", "|": "Vertical bar", "~": "Tilde",
        "<": "Less than", ">": "Greater than", "[": "Left bracket", "]": "Right bracket",
        "{": "Left brace", "}": "Right brace", "•": "Bullet", "€": "Euro sign",
        "£": "Pound sign", "¥": "Yen sign",
    ]
}

enum ShiftState: Equatable {
    case off
    case on
    case locked

    var isUppercase: Bool { self != .off }
}

/// Widths are expressed in letter columns so every row resolves against the
/// same unit. That is what keeps the columns aligned between rows, which fixed
/// point widths could not do across devices.
enum KeyWidth: Equatable {
    case unit
    case multiple(CGFloat)
    /// Shares whatever the fixed keys leave with the other filling keys in the
    /// row, so shift and delete absorb the slack exactly like the system layout.
    case fill
}

enum KeyStyle: Equatable {
    case standard
    case function
    case accent
}

struct KeySpec: Equatable {
    let cap: KeyCap
    var width: KeyWidth = .unit
    var style: KeyStyle = .standard

    static func letter(_ value: String) -> KeySpec {
        KeySpec(cap: .character(value))
    }
}

struct KeyRow: Equatable {
    enum Alignment: Equatable {
        case fill
        /// Keys keep their natural width and the row centres itself, producing
        /// the home row's half-column indent without hardcoding a value.
        case centered
    }

    let keys: [KeySpec]
    var alignment: Alignment = .fill
}

enum KeyLayout {
    /// `leadingPunctuation` is `nil` on the plain letters plane, and that is
    /// what the system keyboard does: an iPhone QWERTY bottom row is `123`,
    /// the globe, space and return — no comma, no full stop. It reappears only
    /// in the fields where iOS puts it back, which are email (`@` and `.`) and
    /// URL (`/` and `.`).
    static func rows(
        for plane: KeyPlane,
        includesGlobe: Bool,
        returnIsProminent: Bool,
        leadingPunctuation: String? = nil
    ) -> [KeyRow] {
        switch plane {
        case .letters:
            return [
                KeyRow(keys: map("qwertyuiop")),
                KeyRow(keys: map("asdfghjkl"), alignment: .centered),
                KeyRow(keys: [KeySpec(cap: .shift, width: .fill, style: .function)]
                    + map("zxcvbnm")
                    + [KeySpec(cap: .delete, width: .fill, style: .function)]),
                bottomRow(
                    planeSwitch: .numbers,
                    punctuation: leadingPunctuation,
                    includesGlobe: includesGlobe,
                    returnIsProminent: returnIsProminent
                ),
            ]
        case .numbers:
            return [
                KeyRow(keys: map("1234567890")),
                KeyRow(keys: map("-/:;()$&@\"")),
                KeyRow(keys: [
                    KeySpec(cap: .plane(.symbols), width: .fill, style: .function)
                ]
                    + map(".,?!'")
                    + [KeySpec(cap: .delete, width: .fill, style: .function)]),
                bottomRow(
                    planeSwitch: .letters,
                    punctuation: nil,
                    includesGlobe: includesGlobe,
                    returnIsProminent: returnIsProminent
                ),
            ]
        case .symbols:
            return [
                KeyRow(keys: map("[]{}#%^*+=")),
                KeyRow(keys: map("_\\|~<>€£¥•")),
                KeyRow(keys: [
                    KeySpec(cap: .plane(.numbers), width: .fill, style: .function)
                ]
                    + map(".,?!'")
                    + [KeySpec(cap: .delete, width: .fill, style: .function)]),
                bottomRow(
                    planeSwitch: .letters,
                    punctuation: nil,
                    includesGlobe: includesGlobe,
                    returnIsProminent: returnIsProminent
                ),
            ]
        }
    }

    /// The narrowest the return key may become. Below this "Continue" and
    /// "Emergency" stop fitting, and the row's most-used non-space target starts
    /// reading as an afterthought.
    static let minimumReturnColumns: CGFloat = 1.75

    /// Column widths that put the spacebar's visible centre on the keyboard's
    /// centre.
    ///
    /// Every key of `c` columns is `c · unit + (c − 1) · gap` wide, and each side
    /// of the spacebar also carries one gap per key. So the span from the row's
    /// leading edge to the spacebar is `C · (unit + gap)` for a group totalling
    /// `C` columns, and the same on the other side — the gaps cancel, and the
    /// spacebar is centred exactly when **the column totals either side of it
    /// are equal**. That identity is the whole calculation; it holds at every
    /// width, which point-based nudging never did.
    struct BottomRowColumns: Equatable {
        var planeSwitch: CGFloat
        var globe: CGFloat?
        var punctuation: CGFloat?
        var period: CGFloat?
        var newline: CGFloat

        var leading: CGFloat { planeSwitch + (globe ?? 0) + (punctuation ?? 0) }
        var trailing: CGFloat { (period ?? 0) + newline }
        /// How far the spacebar's centre sits from the keyboard's, in columns.
        /// Zero is the goal; the sign says which way it leans.
        var centreOffset: CGFloat { (leading - trailing) / 2 }

        static func resolved(includesGlobe: Bool, includesPunctuation: Bool) -> BottomRowColumns {
            let punctuation: CGFloat? = includesPunctuation ? 1 : nil
            var columns = BottomRowColumns(
                planeSwitch: 1.25,
                globe: includesGlobe ? 1.25 : nil,
                punctuation: punctuation,
                period: punctuation,
                newline: 0
            )
            // Return absorbs the difference, because it is the one key on this
            // row with no fixed idea of how wide it should be.
            columns.newline = columns.leading - columns.trailing
            guard columns.newline < minimumReturnColumns else { return columns }
            // Without a globe key the leading group is too light to balance a
            // usable return, so the plane switch takes the slack instead. That
            // is the rare case — iOS requires the globe on a third-party
            // keyboard almost everywhere — and a wider "123" costs nothing.
            columns.newline = minimumReturnColumns
            columns.planeSwitch += columns.trailing - columns.leading
            return columns
        }
    }

    private static func bottomRow(
        planeSwitch: KeyPlane,
        punctuation: String?,
        includesGlobe: Bool,
        returnIsProminent: Bool
    ) -> KeyRow {
        let columns = BottomRowColumns.resolved(
            includesGlobe: includesGlobe,
            includesPunctuation: punctuation != nil
        )
        var keys = [
            KeySpec(
                cap: .plane(planeSwitch),
                width: .multiple(columns.planeSwitch),
                style: .function
            )
        ]
        if let globe = columns.globe {
            keys.append(KeySpec(cap: .globe, width: .multiple(globe), style: .function))
        }
        if let punctuation {
            keys.append(KeySpec(cap: .character(punctuation)))
        }
        keys.append(KeySpec(cap: .space, width: .fill))
        if punctuation != nil {
            keys.append(KeySpec(cap: .character(".")))
        }
        keys.append(
            KeySpec(
                cap: .newline,
                width: .multiple(columns.newline),
                style: returnIsProminent ? .accent : .function
            )
        )
        return KeyRow(keys: keys)
    }

    private static func map(_ characters: String) -> [KeySpec] {
        characters.map { KeySpec.letter(String($0)) }
    }

    /// Title shown on the plane-switch key, mirroring the system keyboard.
    static func planeTitle(_ plane: KeyPlane) -> String {
        switch plane {
        case .letters: "ABC"
        case .numbers: "123"
        case .symbols: "#+="
        }
    }
}

/// Geometry for one rendering of the grid. Everything scales from the trait
/// collection so landscape and iPad stop inheriting portrait iPhone sizing.
struct KeyboardMetrics: Equatable {
    var keyHeight: CGFloat
    var rowGap: CGFloat
    var columnGap: CGFloat
    var sideInset: CGFloat
    var letterFontSize: CGFloat
    var functionFontSize: CGFloat
    var cornerRadius: CGFloat

    var showsPreview: Bool { keyHeight >= 34 }

    var gridHeight: CGFloat { 4 * keyHeight + 3 * rowGap }

    /// Portrait iPhone geometry for one height preference.
    ///
    /// Regular-width iPads and landscape phones are resolved from their traits
    /// instead: a regular/regular canvas has room the preference was never
    /// scaled for, and a compact-height phone has none to give.
    static func resolved(
        for traits: UITraitCollection,
        preference: KeyboardHeightPreference = KeyboardPreferences.keyboardHeight
    ) -> KeyboardMetrics {
        if traits.horizontalSizeClass == .regular, traits.verticalSizeClass == .regular {
            return KeyboardMetrics(
                keyHeight: 56,
                rowGap: 12,
                columnGap: 11,
                sideInset: 8,
                letterFontSize: 24,
                functionFontSize: 17,
                cornerRadius: 7
            )
        }
        if traits.verticalSizeClass == .compact {
            // Landscape phones have very little height to spare; the system
            // keyboard shrinks aggressively here rather than covering the field.
            return KeyboardMetrics(
                keyHeight: 30,
                rowGap: 6,
                columnGap: 5,
                sideInset: 3,
                letterFontSize: 17,
                functionFontSize: 13,
                cornerRadius: 5
            )
        }
        switch preference {
        case .compact:
            return KeyboardMetrics(
                keyHeight: 39,
                rowGap: 8,
                columnGap: 6,
                sideInset: 4,
                letterFontSize: 21,
                functionFontSize: 15,
                cornerRadius: 6
            )
        case .standard:
            return KeyboardMetrics(
                keyHeight: 43,
                rowGap: 10,
                columnGap: 6,
                sideInset: 4,
                letterFontSize: 22,
                functionFontSize: 16,
                cornerRadius: 6
            )
        case .tall:
            return KeyboardMetrics(
                keyHeight: 49,
                rowGap: 11,
                columnGap: 6,
                sideInset: 4,
                letterFontSize: 23,
                functionFontSize: 16,
                cornerRadius: 7
            )
        }
    }
}

/// Concrete colours for one appearance. Resolving eagerly lets the keyboard
/// follow `UITextDocumentProxy.keyboardAppearance`, which a dynamic `UIColor`
/// tied to the trait collection cannot do.
///
/// The keys stay close to the system keyboard's luminance rather than adopting
/// the app's warm paper canvas: a keyboard is a high-frequency input surface
/// that has to read as part of iOS, not as the marketing site. What the brand
/// contributes here is the *accent* — an engaged shift, an editor-prominent
/// return — and nothing else.
struct KeyboardPalette: Equatable {
    let isDark: Bool

    /// Neutral charcoal in dark, neutral grey in light. Both were previously
    /// tinted toward blue, which is the drift the design standard names.
    var background: UIColor {
        isDark ? UIColor(white: 0.086, alpha: 1) : UIColor(white: 0.827, alpha: 1)
    }

    var cardBorder: UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.07)
    }

    /// The brightest key in either appearance, because a character key is what
    /// the eye should land on first.
    var standardKey: UIColor {
        isDark ? UIColor(white: 0.29, alpha: 1) : .white
    }

    /// Visibly a step down from ``standardKey``, and neutral — a muddy or blue
    /// function key is what made the old palette read as someone else's product.
    var functionKey: UIColor {
        isDark ? UIColor(white: 0.184, alpha: 1) : UIColor(white: 0.686, alpha: 1)
    }

    /// The product accent, used only where a key is genuinely *engaged* or
    /// *prominent*: caps lock, an active shift, a Send/Search return.
    var accentKey: UIColor { BrandPalette.accent(isDark: isDark) }

    var keyForeground: UIColor { isDark ? .white : .black }

    /// The stroke a swipe leaves behind it. Opaque by design: ``SwipeTrailView``
    /// fades each piece of the line by its own age, and a colour that arrived
    /// pre-faded would be multiplied by that a second time and disappear.
    ///
    /// The accent rather than a neutral grey, because this is the one gesture
    /// where the keyboard is visibly *interpreting* rather than transcribing,
    /// and it is drawn over keys that are already grey in both appearances.
    var swipeTrail: UIColor { accentKey }

    var label: UIColor { isDark ? .white : .black }

    var secondaryLabel: UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.6)
            : UIColor.black.withAlphaComponent(0.55)
    }

    func background(for style: KeyStyle) -> UIColor {
        switch style {
        case .standard: standardKey
        case .function: functionKey
        case .accent: accentKey
        }
    }

    /// Contrast-tested rather than assumed. The dark-appearance accent is a light
    /// mint, so a hardcoded white label on it sat near 1.7:1.
    func foreground(for style: KeyStyle) -> UIColor {
        style == .accent ? ContrastMath.legibleLabel(on: accentKey) : keyForeground
    }

    /// Pressed function keys swap to the standard key colour and pressed
    /// standard keys swap to the function colour, so a press always reads as a
    /// change even when no preview is shown. No glow: the swap *is* the signal.
    func pressedBackground(for style: KeyStyle) -> UIColor {
        switch style {
        case .standard: functionKey
        case .function: standardKey
        // Shifting toward the appearance's own extreme rather than fading, so a
        // pressed accent key stays opaque and keeps a label contrast at least as
        // good as the one the unpressed key was tested for.
        case .accent: accentKey.blended(with: isDark ? .white : .black, amount: 0.16)
        }
    }
}

private extension UIColor {
    /// A straight linear mix, used for the pressed accent. `withAlphaComponent`
    /// would have let the key background show through a key that is meant to
    /// stay solid.
    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var otherRed: CGFloat = 0
        var otherGreen: CGFloat = 0
        var otherBlue: CGFloat = 0
        var otherAlpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              other.getRed(&otherRed, green: &otherGreen, blue: &otherBlue, alpha: &otherAlpha)
        else { return self }
        let mix = min(max(amount, 0), 1)
        return UIColor(
            red: red + (otherRed - red) * mix,
            green: green + (otherGreen - green) * mix,
            blue: blue + (otherBlue - blue) * mix,
            alpha: 1
        )
    }
}

enum KeyFont {
    /// Key glyphs scale with Dynamic Type but stay bounded, because an unbounded
    /// glyph would overflow a key whose height the grid has already fixed.
    static func scaled(
        _ size: CGFloat,
        maximum: CGFloat,
        weight: UIFont.Weight = .regular
    ) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: size, weight: weight),
            maximumPointSize: maximum
        )
    }
}
