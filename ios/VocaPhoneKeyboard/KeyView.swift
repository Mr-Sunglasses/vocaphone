import UIKit

/// A single key. Deliberately not a `UIButton`: the grid owns touch tracking so
/// a finger can slide between keys and so the hit area can spill into the
/// gutters, neither of which per-control targets can express.
@MainActor
protocol KeyViewAccessibilityDelegate: AnyObject {
    /// A VoiceOver user choosing an accented alternative from the key's custom
    /// actions, which is the path that replaces the long-press gesture.
    func keyView(_ key: KeyView, didChooseAlternative text: String)
    /// VoiceOver's route to the emoji panel, which has no key of its own.
    func keyViewDidRequestEmojiPanel(_ key: KeyView)
}

final class KeyView: UIView {
    let spec: KeySpec
    weak var accessibilityDelegate: (any KeyViewAccessibilityDelegate)?
    /// Mirrors the field's keyboard type, so the VoiceOver actions for `.`
    /// offer domains in the same fields the long press does.
    var alternativesKeyboardType: UIKeyboardType = .default {
        didSet {
            guard alternativesKeyboardType != oldValue else { return }
            updateAlternativeActions()
        }
    }

    /// Touch area including the surrounding gutter. Computed by the grid during
    /// layout because only the grid knows which keys sit against an edge.
    var hitRect: CGRect = .zero

    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            applyColors()
        }
    }

    private let titleLabel = UILabel()
    private let symbolView = UIImageView()
    private var metrics: KeyboardMetrics
    private var palette: KeyboardPalette
    private var shift: ShiftState = .off
    private var returnTitle = "return"

    init(spec: KeySpec, metrics: KeyboardMetrics, palette: KeyboardPalette) {
        self.spec = spec
        self.metrics = metrics
        self.palette = palette
        super.init(frame: .zero)

        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 0.75
        layer.shadowOffset = CGSize(width: 0, height: 1.25)

        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        titleLabel.isUserInteractionEnabled = false
        // Natural size only. Aspect-fitting would scale a 17pt glyph up to the
        // full height of the key.
        symbolView.contentMode = .center
        symbolView.isUserInteractionEnabled = false
        addSubview(titleLabel)
        addSubview(symbolView)

        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = bounds.insetBy(dx: 2, dy: 0)
        symbolView.frame = bounds
        layer.cornerRadius = metrics.cornerRadius
        // Without an explicit path every key forces an offscreen pass to derive
        // its shadow, which is expensive when thirty of them redraw at once.
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: metrics.cornerRadius
        ).cgPath
    }

    func update(
        metrics: KeyboardMetrics,
        palette: KeyboardPalette,
        shift: ShiftState,
        returnTitle: String
    ) {
        // Shift changes on nearly every word, and re-deriving fonts and symbol
        // images for all thirty-odd keys each time is wasted work. Only the keys
        // whose rendering actually depends on the change redraw.
        let shiftChanged = self.shift != shift
        let structuralChange = self.metrics != metrics
            || self.palette != palette
            || self.returnTitle != returnTitle
        self.metrics = metrics
        self.palette = palette
        self.shift = shift
        self.returnTitle = returnTitle
        guard structuralChange || (shiftChanged && dependsOnShift) else { return }
        refresh()
    }

    private var dependsOnShift: Bool {
        spec.cap.isCharacter || spec.cap == .shift
    }

    /// The glyph this key would insert right now, used to fill the preview.
    var previewText: String? {
        spec.cap.resolvedText(shift: shift)
    }

    private func refresh() {
        let symbolFont = UIFont.systemFont(ofSize: metrics.letterFontSize - 3, weight: .medium)
        let symbolConfiguration = UIImage.SymbolConfiguration(font: symbolFont)

        switch spec.cap {
        case .character:
            titleLabel.text = spec.cap.resolvedText(shift: shift)
            titleLabel.font = KeyFont.scaled(
                metrics.letterFontSize,
                maximum: metrics.letterFontSize + 6
            )
            symbolView.image = nil
        case .shift:
            titleLabel.text = nil
            symbolView.image = UIImage(
                systemName: shiftSymbolName,
                withConfiguration: symbolConfiguration
            )
        case .delete:
            titleLabel.text = nil
            symbolView.image = UIImage(
                systemName: "delete.left",
                withConfiguration: symbolConfiguration
            )
        case .globe:
            titleLabel.text = nil
            symbolView.image = UIImage(
                systemName: "globe",
                withConfiguration: symbolConfiguration
            )
        case .space:
            titleLabel.text = "space"
            titleLabel.font = functionFont
            symbolView.image = nil
        case .newline:
            titleLabel.text = returnTitle
            titleLabel.font = functionFont
            symbolView.image = nil
        case let .plane(plane):
            titleLabel.text = KeyLayout.planeTitle(plane)
            titleLabel.font = functionFont
            symbolView.image = nil
        }

        accessibilityLabel = spec.cap.accessibilityLabel(shift: shift)
        updateAlternativeActions()
        if case .plane = spec.cap {
            // The panel has no key of its own, and VoiceOver never receives the
            // long press, so this is how a screen-reader user reaches it.
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Emoji") { [weak self] _ in
                    guard let self else { return false }
                    accessibilityDelegate?.keyViewDidRequestEmojiPanel(self)
                    return true
                },
            ]
        }
        if case .shift = spec.cap {
            accessibilityValue = switch shift {
            case .off: "Off"
            case .on: "On"
            case .locked: "Caps lock"
            }
        }
        applyColors()
    }

    /// The accented forms, offered to VoiceOver as custom actions.
    ///
    /// The long press they mirror is unavailable under VoiceOver — the gesture
    /// is intercepted before the grid ever sees it — so without this the accents
    /// would simply not exist for a screen-reader user. The base character is
    /// dropped from the list: activating the key already types it.
    private func updateAlternativeActions() {
        guard case let .character(base) = spec.cap,
              KeyAlternatives.hasOptions(for: base, keyboardType: alternativesKeyboardType)
        else {
            accessibilityCustomActions = nil
            return
        }
        accessibilityCustomActions = KeyAlternatives
            .options(for: base, shift: shift, keyboardType: alternativesKeyboardType)
            .dropFirst()
            .map { option in
                UIAccessibilityCustomAction(name: option) { [weak self] _ in
                    guard let self else { return false }
                    accessibilityDelegate?.keyView(self, didChooseAlternative: option)
                    return true
                }
            }
    }

    private var functionFont: UIFont {
        KeyFont.scaled(
            metrics.functionFontSize,
            maximum: metrics.functionFontSize + 4,
            weight: .medium
        )
    }

    private var shiftSymbolName: String {
        switch shift {
        case .off: "shift"
        case .on: "shift.fill"
        case .locked: "capslock.fill"
        }
    }

    private func applyColors() {
        // An engaged shift reads as a selected control rather than a pressed
        // one, so it keeps the accent fill until the user turns it off.
        let isShiftEngaged = spec.cap == .shift && shift != .off
        let style: KeyStyle = isShiftEngaged ? .accent : spec.style
        backgroundColor = isHighlighted && !isShiftEngaged
            ? palette.pressedBackground(for: style)
            : palette.background(for: style)
        let foreground = palette.foreground(for: style)
        titleLabel.textColor = foreground
        symbolView.tintColor = foreground
    }
}

/// The magnified glyph shown above a pressed character key. The system keyboard
/// relies on this to confirm what was typed while the fingertip covers the key.
final class KeyPreviewView: UIView {
    private let label = UILabel()

    init(palette: KeyboardPalette, metrics: KeyboardMetrics) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = palette.standardKey
        layer.cornerRadius = metrics.cornerRadius + 4
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 3)

        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.textColor = palette.keyForeground
        label.font = KeyFont.scaled(
            metrics.letterFontSize * 1.6,
            maximum: metrics.letterFontSize * 1.9
        )
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath
    }

    func show(_ text: String) {
        label.text = text
    }
}
