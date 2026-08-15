import UIKit

/// The accented characters a letter key offers on a long press.
///
/// Deliberately a small static map rather than a layout engine. A real
/// multilingual keyboard means per-language layouts, dead keys, transliteration
/// and input-method state; this is the ergonomic slice of that — typing "café"
/// or "Zoë" without leaving the letters plane — and it stops there.
enum KeyAlternatives {
    /// Lowercase forms, ordered by how often they are reached for in the
    /// languages that use the Latin script.
    private static let table: [Character: [String]] = [
        "a": ["á", "à", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["é", "è", "ê", "ë", "ē", "ė", "ę"],
        "i": ["í", "ì", "î", "ï", "ī"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ó", "ò", "ô", "ö", "õ", "ø", "œ", "ō"],
        "s": ["ß", "ś", "š"],
        "u": ["ú", "ù", "û", "ü", "ū"],
        "y": ["ý", "ÿ"],
        "z": ["ź", "ż", "ž"],
    ]

    /// Alternates on the numbers and symbols planes.
    ///
    /// The system keyboard offers these, and they are the ones people actually
    /// hunt for: a currency symbol, a proper dash, an inverted question mark.
    /// Without them the only way to type "€" is to leave vocaphone.
    private static let symbolTable: [Character: [String]] = [
        "-": ["–", "—", "•"],
        "/": ["\\"],
        "$": ["€", "£", "¥", "₹", "¢", "₽", "₩"],
        "&": ["§"],
        "\"": ["\u{201C}", "\u{201D}", "\u{201E}", "«", "»"],
        "'": ["\u{2018}", "\u{2019}", "\u{201A}"],
        "?": ["¿"],
        "!": ["¡"],
        "%": ["‰"],
        "=": ["≠", "≈"],
        "+": ["±"],
        ".": ["…"],
        "0": ["°"],
        "1": ["¹", "½", "¼"],
        "2": ["²"],
        "3": ["³", "¾"],
        "(": ["[", "{", "<"],
        ")": ["]", "}", ">"],
        "•": ["·", "◦"],
    ]

    /// The domains a full stop offers in a URL or email field.
    ///
    /// A small feature that gets used every day, and one of the few places a
    /// keyboard can save a person five taps by knowing what kind of field they
    /// are in.
    static let topLevelDomains = [".com", ".org", ".net", ".co.uk", ".io", ".dev"]

    /// Every option the popover should show for a key, the base character
    /// first.
    ///
    /// The base leads the list and is the initially highlighted option, so
    /// lifting a finger that never moved types exactly what the key says —
    /// the same contract an ordinary tap has.
    ///
    /// Returns an empty array when there is nothing to offer, which is how the
    /// grid decides whether to arm the long press at all.
    static func options(
        for base: String,
        shift: ShiftState,
        keyboardType: UIKeyboardType = .default
    ) -> [String] {
        guard base.count == 1, let key = base.lowercased().first else { return [] }

        // A full stop in a URL or email field means a domain is coming.
        if key == ".", isDomainField(keyboardType) {
            return [base] + topLevelDomains
        }
        if let symbols = symbolTable[key], table[key] == nil {
            // Symbols have no case, so shift changes nothing about them.
            return [base] + symbols
        }
        guard let accents = table[key] else { return [] }
        guard shift.isUppercase else { return [base] + accents }
        // "ß".uppercased() is "SS" — two characters, which is not something a
        // key can commit. Anything without a single-scalar uppercase form is
        // dropped for the shifted plane rather than typed as a digraph.
        let uppercased = accents
            .map { $0.uppercased() }
            .filter { $0.count == 1 }
        return [base.uppercased()] + uppercased
    }

    static func hasOptions(for base: String, keyboardType: UIKeyboardType = .default) -> Bool {
        guard base.count == 1, let key = base.lowercased().first else { return false }
        if key == ".", isDomainField(keyboardType) { return true }
        return table[key] != nil || symbolTable[key] != nil
    }

    static func isDomainField(_ keyboardType: UIKeyboardType) -> Bool {
        switch keyboardType {
        case .URL, .emailAddress, .webSearch: true
        default: false
        }
    }
}

/// The row of alternatives shown above a held letter key.
///
/// It draws itself in the key palette with the same continuous corners and the
/// same single restrained shadow as ``KeyPreviewView``, so a long press reads as
/// the preview growing rather than as a different piece of software arriving.
final class KeyAlternativesView: UIView {
    private(set) var options: [String] = []
    private(set) var highlightedIndex = 0

    private var labels: [UILabel] = []
    private var palette: KeyboardPalette
    private var metrics: KeyboardMetrics

    /// Wide enough for a fingertip, which is the whole point of the popover.
    private static let optionWidth: CGFloat = 40
    private static let optionSpacing: CGFloat = 2
    private static let padding: CGFloat = 5

    init(palette: KeyboardPalette, metrics: KeyboardMetrics) {
        self.palette = palette
        self.metrics = metrics
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        // The row is announced by the key's custom actions, not by the popover:
        // VoiceOver never drives this gesture. See `KeyView.accessibility…`.
        isAccessibilityElement = false
        backgroundColor = palette.standardKey
        layer.cornerRadius = metrics.cornerRadius + 5
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var optionHeight: CGFloat { metrics.keyHeight }

    func size(for options: [String]) -> CGSize {
        let count = CGFloat(max(options.count, 1))
        return CGSize(
            width: count * Self.optionWidth
                + (count - 1) * Self.optionSpacing
                + 2 * Self.padding,
            height: optionHeight + 2 * Self.padding
        )
    }

    func show(_ options: [String], palette: KeyboardPalette, metrics: KeyboardMetrics) {
        self.palette = palette
        self.metrics = metrics
        self.options = options
        highlightedIndex = 0
        backgroundColor = palette.standardKey
        layer.cornerRadius = metrics.cornerRadius + 5

        while labels.count < options.count {
            let label = UILabel()
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.layer.cornerRadius = metrics.cornerRadius
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            addSubview(label)
            labels.append(label)
        }
        for (index, label) in labels.enumerated() {
            label.isHidden = index >= options.count
            guard index < options.count else { continue }
            label.text = options[index]
            label.font = KeyFont.scaled(
                metrics.letterFontSize,
                maximum: metrics.letterFontSize + 4
            )
        }
        applyHighlight()
        setNeedsLayout()
    }

    /// Moves the selection to whichever option the finger is over, clamped to
    /// the ends so a finger dragged past the edge keeps the nearest option
    /// rather than losing the selection entirely.
    ///
    /// Returns whether the selection changed, so the caller can decide about
    /// feedback without re-reading state.
    @discardableResult
    func highlightOption(atX x: CGFloat) -> Bool {
        guard !options.isEmpty else { return false }
        let step = Self.optionWidth + Self.optionSpacing
        let raw = Int(((x - Self.padding) / step).rounded(.down))
        let clamped = min(max(raw, 0), options.count - 1)
        guard clamped != highlightedIndex else { return false }
        highlightedIndex = clamped
        applyHighlight()
        return true
    }

    var highlightedOption: String? {
        guard options.indices.contains(highlightedIndex) else { return nil }
        return options[highlightedIndex]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let step = Self.optionWidth + Self.optionSpacing
        for (index, label) in labels.enumerated() where index < options.count {
            label.frame = CGRect(
                x: Self.padding + CGFloat(index) * step,
                y: Self.padding,
                width: Self.optionWidth,
                height: optionHeight
            )
        }
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath
    }

    private func applyHighlight() {
        for (index, label) in labels.enumerated() where index < options.count {
            let isSelected = index == highlightedIndex
            label.backgroundColor = isSelected ? palette.accentKey : .clear
            label.textColor = isSelected
                ? ContrastMath.legibleLabel(on: palette.accentKey)
                : palette.keyForeground
        }
    }
}
