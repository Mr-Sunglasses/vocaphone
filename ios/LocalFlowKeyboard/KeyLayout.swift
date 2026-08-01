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
    static func rows(
        for plane: KeyPlane,
        includesGlobe: Bool,
        returnIsProminent: Bool,
        leadingPunctuation: String = ","
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

    private static func bottomRow(
        planeSwitch: KeyPlane,
        punctuation: String?,
        includesGlobe: Bool,
        returnIsProminent: Bool
    ) -> KeyRow {
        var keys = [
            KeySpec(cap: .plane(planeSwitch), width: .multiple(1.25), style: .function)
        ]
        if includesGlobe {
            keys.append(KeySpec(cap: .globe, width: .multiple(1.25), style: .function))
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
                width: .multiple(2.25),
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

    static func resolved(for traits: UITraitCollection) -> KeyboardMetrics {
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
        return KeyboardMetrics(
            keyHeight: 43,
            rowGap: 10,
            columnGap: 6,
            sideInset: 4,
            letterFontSize: 22,
            functionFontSize: 16,
            cornerRadius: 6
        )
    }
}

/// Concrete colours for one appearance. Resolving eagerly lets the keyboard
/// follow `UITextDocumentProxy.keyboardAppearance`, which a dynamic `UIColor`
/// tied to the trait collection cannot do.
struct KeyboardPalette: Equatable {
    let isDark: Bool

    var background: UIColor {
        isDark
            ? UIColor(red: 0.075, green: 0.082, blue: 0.095, alpha: 1)
            : UIColor(red: 0.82, green: 0.835, blue: 0.86, alpha: 1)
    }

    var card: UIColor {
        isDark
            ? UIColor(red: 0.145, green: 0.155, blue: 0.18, alpha: 1)
            : UIColor(red: 0.97, green: 0.975, blue: 0.985, alpha: 1)
    }

    var cardBorder: UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.07)
    }

    var standardKey: UIColor {
        isDark ? UIColor(red: 0.275, green: 0.29, blue: 0.325, alpha: 1) : .white
    }

    var functionKey: UIColor {
        isDark
            ? UIColor(red: 0.17, green: 0.18, blue: 0.205, alpha: 1)
            : UIColor(red: 0.66, green: 0.685, blue: 0.72, alpha: 1)
    }

    var toolbarControl: UIColor {
        isDark
            ? UIColor(red: 0.2, green: 0.215, blue: 0.245, alpha: 1)
            : UIColor(white: 0.95, alpha: 1)
    }

    var keyForeground: UIColor { isDark ? .white : .black }

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
        case .accent: .systemBlue
        }
    }

    func foreground(for style: KeyStyle) -> UIColor {
        style == .accent ? .white : keyForeground
    }

    /// Pressed function keys swap to the standard key colour and pressed
    /// standard keys swap to the function colour, so a press always reads as a
    /// change even when no preview is shown.
    func pressedBackground(for style: KeyStyle) -> UIColor {
        switch style {
        case .standard: functionKey
        case .function: standardKey
        case .accent: UIColor.systemBlue.withAlphaComponent(0.75)
        }
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
