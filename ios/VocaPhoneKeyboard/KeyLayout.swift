import UIKit

enum KeyPlane: Equatable {
    case letters
    case numbers
    case symbols
    /// The three numeric layouts iOS gives a field that asks for one.
    ///
    /// These are not "the numbers plane with a different starting point", which
    /// is what a `.numberPad` field used to get: a full QWERTY symbols row
    /// reading `-/:;()$&@"` above a phone-number box does not read as a
    /// variant, it reads as a keyboard that has not noticed where it is. They
    /// have no plane switch, because there is nowhere else for them to go.
    case numberPad
    case phonePad
    case decimalPad

    /// Whether this plane is one of the numeric keypads, which share a shape
    /// and share the rule that the user cannot leave them.
    var isKeypad: Bool {
        switch self {
        case .numberPad, .phonePad, .decimalPad: true
        case .letters, .numbers, .symbols: false
        }
    }
}

/// The space around the keys that belongs to the keyboard rather than to any
/// key, in points.
///
/// Three views have to agree about these two numbers, and they used to hold
/// five copies between two files, tied together by a comment. The stack lays
/// the gap out, the grid claims it — a stack's spacing belongs to no subview,
/// so a touch landing there is delivered to nobody — and the stack's own hit
/// test forwards from both. Changing one copy and not the others is silent:
/// the stack simply starts claiming a strip the grid does not answer for.
enum KeyboardChrome {
    /// Between the dictation bar and the top row.
    static let gapAboveKeys: CGFloat = 12
    /// Beyond the grid's left and right edges, out into the keyboard's own
    /// margin — wider than that margin, so a thumb landing on the bezel side
    /// of `a` or `l` is not thrown away.
    static let sideMargin: CGFloat = 8
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
    /// Steps to the next enabled layout. Distinct from ``globe``, which leaves
    /// for somebody else's keyboard: these are two different destinations and
    /// sharing one key made the common one cost a long press.
    case layoutSwitch
    /// A hole in the grid. The numeric keypads are a 3x4 block with one empty
    /// corner, and iOS leaves that corner genuinely empty rather than
    /// stretching its neighbours across it.
    case blank

    /// Character keys are the only ones that show a preview and accept a finger
    /// sliding in from a neighbour, matching the system keyboard.
    var isCharacter: Bool {
        if case .character = self { return true }
        return false
    }

    /// Whether this key can be pressed at all. A blank is laid out and drawn as
    /// nothing, and must never take a touch from the keys either side of it.
    var isInteractive: Bool { self != .blank }

    /// A name for this key in a touch trace. Not user-facing.
    var traceName: String {
        switch self {
        case let .character(base): base
        default: String(describing: self).prefix(12).description
        }
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
        case .layoutSwitch: return "Next language"
        case .blank: return ""
        case let .plane(plane):
            switch plane {
            case .letters: return "Letters"
            case .numbers: return "Numbers"
            case .symbols: return "Symbols"
            case .numberPad, .phonePad, .decimalPad: return "Numbers"
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
    /// How many columns this row is measured against, when that is not the
    /// alphabet's own count.
    ///
    /// The letter rows set the unit — ten for QWERTY, eleven for ЙЦУКЕН — and
    /// every row that is *made of letters* should follow it, so the columns
    /// line up. The bottom row is not made of letters: the spacebar, Return
    /// and the plane key are the same keys in every language, and letting a
    /// wider alphabet shrink them means the whole bottom of the keyboard moves
    /// under the thumb when the language changes. It stays on ten.
    var columnReference: CGFloat?
}

enum KeyLayout {
    /// `leadingPunctuation` is `nil` on the plain letters plane, and that is
    /// what the system keyboard does: an iPhone QWERTY bottom row is `123`,
    /// the globe, space and return — no comma, no full stop. It reappears only
    /// in the fields where iOS puts it back, which are email (`@` and `.`) and
    /// URL (`/` and `.`).
    static func rows(
        for plane: KeyPlane,
        layout: TypingLayout = .fallback,
        includesGlobe: Bool,
        includesLayoutSwitch: Bool = false,
        returnIsProminent: Bool,
        punctuation: BottomRowPunctuation? = nil
    ) -> [KeyRow] {
        switch plane {
        case .numberPad, .phonePad, .decimalPad:
            return keypadRows(for: plane, includesGlobe: includesGlobe)
        case .letters:
            return letterRows(for: layout) + [
                bottomRow(
                    planeSwitch: .numbers,
                    punctuation: punctuation,
                    includesGlobe: includesGlobe,
                    includesLayoutSwitch: includesLayoutSwitch,
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
                    + fillMap(".,?!'")
                    + [KeySpec(cap: .delete, width: .fill, style: .function)]),
                bottomRow(
                    planeSwitch: .letters,
                    punctuation: nil,
                    includesGlobe: includesGlobe,
                    includesLayoutSwitch: includesLayoutSwitch,
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
                    + fillMap(".,?!'")
                    + [KeySpec(cap: .delete, width: .fill, style: .function)]),
                bottomRow(
                    planeSwitch: .letters,
                    punctuation: nil,
                    includesGlobe: includesGlobe,
                    includesLayoutSwitch: includesLayoutSwitch,
                    returnIsProminent: returnIsProminent
                ),
            ]
        }
    }

    /// Apple's iPhone bottom row gives Return two and a half letter columns.
    /// Besides matching its visual weight, this keeps longer return labels such
    /// as "Continue" from becoming a much smaller target than users expect.
    static let minimumReturnColumns: CGFloat = 2.5

    /// Return's width once a language key has joined the row.
    ///
    /// Below Apple's 2.5, and deliberately: the spacebar is the key this row
    /// exists to carry, and a Return that keeps a quarter of the row while the
    /// spacebar shrinks to a thumb's width has the priorities backwards. At
    /// 1.75 a "Continue" label still fits — it is the same width Return has on
    /// the numbers plane, where nobody has ever called it small.
    static let crowdedReturnColumns: CGFloat = 1.75

    /// The width below which the spacebar stops reading as one.
    ///
    /// Apple's plain row gives it five columns of ten. Four is the point where
    /// a thumb aiming for the middle of the bar can still miss by a column and
    /// land on it, which is what the key is for; below that it is a wide comma.
    static let minimumSpacebarColumns: CGFloat = 4

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
    /// The two punctuation keys iOS adds to the bottom row in the handful of
    /// field types that earn them.
    ///
    /// A pair rather than a single leading key, because the second slot is not
    /// always a full stop: a `.twitter` field gets `@` and `#`, which are the
    /// two characters that field is *for*, and hard-coding "." there was why it
    /// could not be offered.
    struct BottomRowPunctuation: Equatable {
        let leading: String
        let trailing: String

        static let period = BottomRowPunctuation(leading: ",", trailing: ".")
    }

    struct BottomRowColumns: Equatable {
        var planeSwitch: CGFloat
        var globe: CGFloat?
        var layoutSwitch: CGFloat?
        var punctuation: CGFloat?
        var period: CGFloat?
        var newline: CGFloat

        var leading: CGFloat {
            planeSwitch + (globe ?? 0) + (layoutSwitch ?? 0) + (punctuation ?? 0)
        }
        var trailing: CGFloat { (period ?? 0) + newline }
        /// How far the spacebar's centre sits from the keyboard's, in columns.
        /// Zero is the goal; the sign says which way it leans.
        var centreOffset: CGFloat { (leading - trailing) / 2 }
        /// What is left for the spacebar, which is the key this row exists to
        /// carry and the only one whose width is decided by subtraction.
        var spacebar: CGFloat { 10 - leading - trailing }

        static func resolved(
            includesGlobe: Bool,
            includesLayoutSwitch: Bool = false,
            includesPunctuation: Bool
        ) -> BottomRowColumns {
            // Measured on Apple's iOS 26 keyboard at the same 402pt width:
            //   plain:  2.5 |       5       | 2.5
            //   globe:  1.25 | 1.25 | 5     | 2.5
            //   email:  1.25 | 1.25 | 2.5 | 1.25 | 1.25 | 2.5
            // iOS sometimes supplies the globe in its own row below the
            // extension. In that case 123 occupies the two native leading
            // slots instead of leaving Space unnaturally wide.
            // A language key is a fifth thing on a row Apple balances with
            // four, and something has to give. The first attempt gave the
            // same thing away every time — every function key trimmed to a
            // column, Return to 1.75 — which on a row with no punctuation
            // handed the spacebar six and a quarter columns against Apple's
            // five, and left the keys either side of it visibly thin. Wrong
            // in both directions at once.
            //
            // So nothing is trimmed until the row is actually short of room.
            // Apple's widths are tried first; Return gives way before the
            // function keys do, because Return has the most to spare and is
            // the least often aimed at; and the trimming stops as soon as the
            // spacebar is back above the width below which it stops reading
            // as a spacebar.
            guard includesLayoutSwitch else {
                let punctuation: CGFloat? = includesPunctuation ? 1.25 : nil
                return BottomRowColumns(
                    planeSwitch: includesGlobe ? 1.25 : 2.5,
                    globe: includesGlobe ? 1.25 : nil,
                    layoutSwitch: nil,
                    punctuation: punctuation,
                    period: punctuation,
                    newline: minimumReturnColumns
                )
            }
            func row(function: CGFloat, newline: CGFloat) -> BottomRowColumns {
                let punctuation: CGFloat? = includesPunctuation ? function : nil
                return BottomRowColumns(
                    planeSwitch: function,
                    globe: includesGlobe ? function : nil,
                    layoutSwitch: function,
                    punctuation: punctuation,
                    period: punctuation,
                    newline: newline
                )
            }
            let candidates = [
                row(function: 1.25, newline: minimumReturnColumns),
                row(function: 1.25, newline: crowdedReturnColumns),
                row(function: 1, newline: minimumReturnColumns),
                row(function: 1, newline: crowdedReturnColumns),
            ]
            // Of the rows that leave the spacebar wide enough, the one whose
            // column totals either side of it come closest to equal — which is
            // the identity that puts its visible centre on the keyboard's, and
            // the thing a ladder of "trim this, then that" quietly destroys.
            let roomy = candidates.filter { $0.spacebar >= minimumSpacebarColumns }
            return roomy.min { abs($0.centreOffset) < abs($1.centreOffset) }
                ?? candidates[candidates.count - 1]
        }
    }

    /// The three letter rows of a layout, above the bottom row every plane
    /// shares.
    ///
    /// The rows are the layout's own, and their *lengths* are what differs:
    /// QWERTY is 10/9/7, ЙЦУКЕН is 11/11/9, AZERTY is 10/10/6. Nothing here
    /// sets a width — ``KeyGridView`` reads its column unit off the rows it is
    /// handed, so an eleven-key row simply produces narrower keys.
    ///
    /// The middle row centres itself only when it is shorter than the row above
    /// it. That is the derivation behind QWERTY's familiar half-column indent,
    /// and it is why Spanish, whose middle row is the longer one at ten keys
    /// with ñ on the end, correctly does not indent.
    private static func letterRows(for layout: TypingLayout) -> [KeyRow] {
        let letters = layout.rows
        let top = letters.first?.count ?? 0
        return letters.enumerated().map { index, row in
            if index == letters.count - 1 {
                return KeyRow(keys: [KeySpec(cap: .shift, width: .fill, style: .function)]
                    + map(row)
                    + [KeySpec(cap: .delete, width: .fill, style: .function)])
            }
            return KeyRow(
                keys: map(row),
                alignment: row.count < top ? .centered : .fill
            )
        }
    }

    private static func bottomRow(
        planeSwitch: KeyPlane,
        punctuation: BottomRowPunctuation?,
        includesGlobe: Bool,
        includesLayoutSwitch: Bool,
        returnIsProminent: Bool
    ) -> KeyRow {
        let columns = BottomRowColumns.resolved(
            includesGlobe: includesGlobe,
            includesLayoutSwitch: includesLayoutSwitch,
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
        if let layoutSwitch = columns.layoutSwitch {
            keys.append(
                KeySpec(cap: .layoutSwitch, width: .multiple(layoutSwitch), style: .function)
            )
        }
        if let punctuation {
            keys.append(
                KeySpec(
                    cap: .character(punctuation.leading),
                    width: .multiple(columns.punctuation ?? 1)
                )
            )
        }
        keys.append(KeySpec(cap: .space, width: .fill))
        if let punctuation {
            keys.append(
                KeySpec(
                    cap: .character(punctuation.trailing),
                    width: .multiple(columns.period ?? 1)
                )
            )
        }
        keys.append(
            KeySpec(
                cap: .newline,
                width: .multiple(columns.newline),
                style: returnIsProminent ? .accent : .function
            )
        )
        return KeyRow(keys: keys, columnReference: 10)
    }

    /// The three-column numeric block iOS shows for a `.numberPad`,
    /// `.phonePad` or `.decimalPad` field.
    ///
    /// Four rows, so it occupies exactly the height the letters plane does and
    /// the keyboard does not resize under the user when the cursor moves from a
    /// name field to a phone-number one. The bottom-left slot carries the globe
    /// where iOS asks for one and is genuinely empty otherwise, which is what
    /// the system keypad does — a stretched `0` there would be a target people
    /// hit by accident reaching for nothing.
    static func keypadRows(for plane: KeyPlane, includesGlobe: Bool) -> [KeyRow] {
        // Three columns in every row. The system keypad is a regular block and
        // reads as one; a bottom row of four keys under three is a grid that has
        // come apart.
        //
        // The bottom row is the exception, and only where it has to be. A
        // decimal pad's "." and a phone pad's "+" are the *only* way to type
        // those characters — these layouts have no second plane and no duplicate
        // key — so when iOS also demands a globe there are four things that must
        // be reachable and three slots. Giving the corner to the globe left a
        // decimal pad that could not type a decimal point, which is not a
        // narrower keyboard, it is a broken one. The row takes a fourth key
        // instead; the digits above it stay on three.
        var last: [KeySpec] = []
        if includesGlobe {
            last.append(KeySpec(cap: .globe, width: .multiple(keypadColumns), style: .function))
        }
        switch plane {
        case .decimalPad:
            last.append(KeySpec(cap: .character("."), width: .multiple(keypadColumns)))
        case .phonePad:
            last.append(KeySpec(cap: .character("+"), width: .multiple(keypadColumns)))
        default:
            break
        }
        // A plain number pad with no globe has nothing for the corner, and iOS
        // leaves it genuinely empty rather than stretching the zero across it —
        // a target people would hit reaching for nothing.
        if last.isEmpty {
            last.append(KeySpec(cap: .blank, width: .multiple(keypadColumns)))
        }
        last.append(KeySpec(cap: .character("0"), width: .multiple(keypadColumns)))
        last.append(KeySpec(cap: .delete, width: .multiple(keypadColumns), style: .function))

        return [
            keypadRow("123"),
            keypadRow("456"),
            keypadRow("789"),
            KeyRow(keys: last, alignment: .centered),
        ]
    }

    /// How wide one keypad key is, in letter columns. Three of them plus their
    /// gaps come to a little over two thirds of the keyboard, which is where the
    /// system keypad sits: wide enough to be unmissable, narrow enough that the
    /// block still reads as a keypad rather than as a stretched row.
    static let keypadColumns: CGFloat = 2.4

    private static func keypadRow(_ digits: String) -> KeyRow {
        KeyRow(keys: keypadSpecs(digits), alignment: .centered)
    }

    private static func keypadSpecs(_ digits: String) -> [KeySpec] {
        digits.map {
            KeySpec(cap: .character(String($0)), width: .multiple(keypadColumns))
        }
    }

    private static func map(_ characters: String) -> [KeySpec] {
        characters.map { KeySpec.letter(String($0)) }
    }

    /// Character keys that share the row's slack instead of standing at one
    /// letter column each.
    ///
    /// The punctuation row of the numbers and symbols planes has seven keys
    /// against the ten columns above it. Leaving the five characters at a
    /// column apiece handed all three spare columns to `#+=` and Delete, which
    /// came out at two and a half columns each — two slabs on either side of
    /// five narrow punctuation keys. The system divides that row evenly, and
    /// the keys people actually reach for there are the punctuation.
    private static func fillMap(_ characters: String) -> [KeySpec] {
        characters.map { KeySpec(cap: .character(String($0)), width: .fill) }
    }

    /// Title shown on the plane-switch key, mirroring the system keyboard.
    static func planeTitle(_ plane: KeyPlane) -> String {
        switch plane {
        case .letters: "ABC"
        case .numbers: "123"
        case .symbols: "#+="
        // The keypads have no plane key to put a title on; the case exists so
        // adding a plane later cannot silently inherit the wrong label.
        case .numberPad, .phonePad, .decimalPad: "123"
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
    /// The glyph sizes and radii are read off the system keyboard rather than
    /// derived: a letter is roughly 0.58 of the key's height and the corner is
    /// roughly 0.23 of it. The keyboard this replaced sat at 0.51 and 0.14,
    /// which is what "small letters on square keys" measures out to.
    ///
    /// Note that the system does *not* scale its key glyphs with Dynamic Type.
    /// ``KeyFont/scaled(_:maximum:weight:)`` still does, within a bound, which
    /// is a deliberate difference and the reason the maximum exists.
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
                letterFontSize: 25,
                functionFontSize: 18,
                cornerRadius: 10
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
                letterFontSize: 18,
                functionFontSize: 14,
                cornerRadius: 7
            )
        }
        switch preference {
        case .compact:
            return KeyboardMetrics(
                keyHeight: 39,
                rowGap: 9,
                columnGap: 6,
                sideInset: 2 / 3,
                letterFontSize: 23,
                functionFontSize: 16,
                cornerRadius: 9
            )
        case .standard:
            return KeyboardMetrics(
                keyHeight: 43,
                rowGap: 11,
                columnGap: 6,
                sideInset: 2 / 3,
                letterFontSize: 24,
                functionFontSize: 17,
                cornerRadius: 10
            )
        case .tall:
            return KeyboardMetrics(
                keyHeight: 49,
                rowGap: 12,
                columnGap: 6,
                sideInset: 2 / 3,
                // 0.55 of the key, like the other two heights. It was 0.51
                // here — the tall keyboard kept the old proportion when the
                // others were corrected, which is the sort of thing nobody
                // notices until the ratio is written down as a test.
                letterFontSize: 27,
                functionFontSize: 17,
                cornerRadius: 11
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
/// contributes here is the *accent* — an editor-prominent return and the swipe
/// trail — and nothing else.
struct KeyboardPalette: Equatable {
    let isDark: Bool

    private var usesUnifiedSystemKeyFill: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Whether the extension may leave the surface behind the keys unpainted
    /// and let `UIInputView`'s keyboard style draw it.
    ///
    /// ``background`` below is this project's guess at the colour iOS puts
    /// behind a keyboard, and a guess is exactly what makes a keyboard read as
    /// somebody else's product: it is one grey nothing else on the phone uses.
    /// The input view the extension is handed already draws the real thing, in
    /// every host, both appearances, and the next iOS as well.
    ///
    /// ``background`` stays for the surfaces that have no input view to borrow
    /// it from — the settings preview and the SwiftUI canvases.
    var usesSystemKeyboardBackdrop: Bool { usesUnifiedSystemKeyFill }

    /// Neutral charcoal in dark, neutral grey in light. Both were previously
    /// tinted toward blue, which is the drift the design standard names.
    var background: UIColor {
        if usesUnifiedSystemKeyFill {
            return isDark
                ? UIColor(white: 23 / 255, alpha: 1)
                : UIColor(red: 226 / 255, green: 228 / 255, blue: 232 / 255, alpha: 1)
        }
        return isDark ? UIColor(white: 0.086, alpha: 1) : UIColor(white: 0.827, alpha: 1)
    }

    var cardBorder: UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.07)
    }

    /// The brightest key in either appearance, because a character key is what
    /// the eye should land on first.
    ///
    /// In dark this is *translucent*, and that is the whole point. The 61/255
    /// this replaces was read off a screenshot of the system keyboard sitting
    /// on its own near-black backdrop — a true pixel, but a composite one. The
    /// system draws a light film over whatever is behind the keyboard, so on
    /// Spotlight or over a bright wallpaper its keys lift and stay legible,
    /// while an opaque 61/255 stays flat black wherever it is put. That is the
    /// difference between this keyboard and the system one on a home screen.
    ///
    /// The alpha is chosen to reproduce the measured pixel exactly against the
    /// backdrop it was measured on: 23 + (255 − 23) × 0.164 ≈ 61.
    var standardKey: UIColor {
        if usesUnifiedSystemKeyFill {
            // Declared in RGB rather than `UIColor(white:alpha:)`: the
            // contrast maths reads colours through `getRed`, which reports
            // nothing for a translucent monochrome colour and silently scores
            // it as black. Everything else in this palette is RGB for the same
            // reason.
            return isDark ? UIColor(red: 1, green: 1, blue: 1, alpha: 0.164) : .white
        }
        return isDark ? UIColor(white: 0.29, alpha: 1) : .white
    }

    /// The fill for a surface that floats *above* the keys — the magnified
    /// preview balloon and the accent popover.
    ///
    /// Flattened, not filmed. ``standardKey`` is translucent in dark so a key
    /// can pick up whatever the keyboard is standing on, but a balloon lifted
    /// over the row is standing on the keys themselves: left translucent, it
    /// shows the letters it exists to cover, which is what a magnified preview
    /// is for.
    var raisedKey: UIColor { standardKey.compositedOver(background) }

    /// Visibly a step down from ``standardKey``, and neutral — a muddy or blue
    /// function key is what made the old palette read as someone else's product.
    var functionKey: UIColor {
        if usesUnifiedSystemKeyFill { return standardKey }
        return isDark
            ? UIColor(white: 0.184, alpha: 1)
            : UIColor(white: 0.686, alpha: 1)
    }

    /// The product accent, used only where a key is genuinely prominent, such
    /// as a Send/Search return, or for the swipe trail.
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
        return switch style {
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

    /// A press always reads as a change even when no preview is shown. Unified
    /// iOS 26 keys darken or lighten; earlier palettes swap their two neutral
    /// fills. No glow: the fill change is the signal.
    func pressedBackground(for style: KeyStyle) -> UIColor {
        if usesUnifiedSystemKeyFill, style != .accent {
            return background(for: style).blended(
                with: isDark ? .white : .black,
                amount: 0.16
            )
        }
        return switch style {
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
        // Through `ContrastMath.rgba`, which falls back to `getWhite`.
        //
        // `getRed` answers nothing for a monochrome colour, and the two this is
        // always mixed with — `.white` and `.black` — are exactly that. The
        // guard then returned the colour unchanged, so on any build where that
        // happens a pressed key kept its resting fill: the press had no visible
        // effect at all. This is the same trap the luminance maths was just
        // taken out of, one file away.
        guard let base = ContrastMath.rgba(self),
              let mixer = ContrastMath.rgba(other)
        else { return self }
        let (red, green, blue, alpha) = base
        let (otherRed, otherGreen, otherBlue, otherAlpha) = mixer
        let mix = min(max(amount, 0), 1)
        return UIColor(
            red: red + (otherRed - red) * mix,
            green: green + (otherGreen - green) * mix,
            blue: blue + (otherBlue - blue) * mix,
            // Alpha mixes with everything else. Pinning it to 1 was safe while
            // every fill here was opaque; against the translucent dark key it
            // turned a press into solid white — with white labels on it. The
            // accent this was written for still comes out solid, because its
            // own alpha is 1 and mixing 1 with 1 is 1.
            alpha: alpha + (otherAlpha - alpha) * mix
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
