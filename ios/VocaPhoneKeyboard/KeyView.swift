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
            // The system spacebar is visually blank; its name remains available
            // through the key's accessibility label.
            titleLabel.text = nil
            symbolView.image = nil
        case .newline:
            if returnTitle == "return" {
                titleLabel.text = nil
                symbolView.image = UIImage(
                    systemName: "return",
                    withConfiguration: symbolConfiguration
                )
            } else {
                titleLabel.text = returnTitle
                titleLabel.font = functionFont
                symbolView.image = nil
            }
        case let .plane(plane):
            titleLabel.text = KeyLayout.planeTitle(plane)
            titleLabel.font = planeFont
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

    private var planeFont: UIFont {
        KeyFont.scaled(
            metrics.functionFontSize + 4,
            maximum: metrics.functionFontSize + 6
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
        // Apple's Shift stays on the neutral key surface; its filled Shift or
        // Caps Lock glyph carries the state. A persistent mint key made the
        // resting keyboard look active and unlike the keyboard users know.
        let style = spec.style
        backgroundColor = isHighlighted
            ? palette.pressedBackground(for: style)
            : palette.background(for: style)
        let foreground = palette.foreground(for: style)
        titleLabel.textColor = foreground
        symbolView.tintColor = foreground
    }
}

/// The magnified glyph shown above a pressed character key. The system keyboard
/// relies on this to confirm what was typed while the fingertip covers the key.
///
/// Drawn as one path rather than a floating rounded rectangle. iOS joins the
/// balloon to the key with a tapered neck, and a bubble hovering over a gap is
/// the detail that gives a third-party keyboard away at a glance. The view
/// therefore spans from the top of the balloon down to the bottom of the key,
/// and ``show(_:balloonHeight:neck:)`` is told where the key sits inside it.
final class KeyPreviewView: UIView {
    private let label = UILabel()
    private let shape = CAShapeLayer()
    private let keyCornerRadius: CGFloat
    private let balloonCornerRadius: CGFloat
    private var balloonHeight: CGFloat = 0
    private var neck: CGRect = .zero

    init(palette: KeyboardPalette, metrics: KeyboardMetrics) {
        keyCornerRadius = metrics.cornerRadius
        balloonCornerRadius = metrics.cornerRadius + 4
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        // The shape carries the fill and the shadow; the view itself must not
        // paint a rectangle behind it.
        backgroundColor = .clear
        shape.fillColor = palette.standardKey.cgColor
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.22
        shape.shadowRadius = 5
        shape.shadowOffset = CGSize(width: 0, height: 3)
        layer.addSublayer(shape)

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
        // Geometry changes here are driven by the finger, so the implicit
        // animation on a shape layer's path would smear the glyph across the
        // keyboard as the touch slides between keys.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        let path = outline().cgPath
        shape.path = path
        shape.shadowPath = path
        CATransaction.commit()
        // The glyph belongs in the balloon, not centred over the whole view —
        // the neck is the key the finger is already covering.
        label.frame = CGRect(x: 0, y: 0, width: bounds.width, height: balloonHeight)
    }

    func show(_ text: String, balloonHeight: CGFloat, neck: CGRect) {
        label.text = text
        self.balloonHeight = balloonHeight
        self.neck = neck
        setNeedsLayout()
    }

    /// The balloon, the tapered shoulders, and the neck over the key, as one
    /// closed path drawn clockwise from the balloon's top-left corner.
    private func outline() -> UIBezierPath {
        let width = bounds.width
        let height = bounds.height
        let balloonBottom = balloonHeight
        // A neck wider than the balloon, or one that has not been set yet,
        // would fold the path inside out. Fall back to the plain balloon.
        let minX = max(neck.minX, 0)
        let maxX = min(neck.maxX, width)
        guard balloonBottom > 0, height > balloonBottom, maxX - minX > 0, minX > 0 || maxX < width
        else {
            return UIBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: width, height: max(height, 1)),
                cornerRadius: balloonCornerRadius
            )
        }

        let corner = min(balloonCornerRadius, width / 2, balloonBottom / 2)
        let keyCorner = min(keyCornerRadius, (maxX - minX) / 2)
        // How far the taper runs up into the balloon, and how far it runs down
        // past the balloon before the neck settles vertical. The curve between
        // them is cubic with both control points on the verticals it joins, so
        // the shoulder leaves the balloon and meets the neck without a corner —
        // the long concave sweep is most of what makes the system's preview
        // read as one moulded shape rather than a box on a stick.
        let shoulder = min(balloonBottom * 0.45, 20)
        let drop = min((height - balloonBottom) * 0.35, 14)

        let path = UIBezierPath()
        path.move(to: CGPoint(x: corner, y: 0))
        path.addLine(to: CGPoint(x: width - corner, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: width, y: corner),
            controlPoint: CGPoint(x: width, y: 0)
        )
        path.addLine(to: CGPoint(x: width, y: balloonBottom - shoulder))
        path.addCurve(
            to: CGPoint(x: maxX, y: balloonBottom + drop),
            controlPoint1: CGPoint(x: width, y: balloonBottom + drop * 0.55),
            controlPoint2: CGPoint(x: maxX, y: balloonBottom - shoulder * 0.55)
        )
        path.addLine(to: CGPoint(x: maxX, y: height - keyCorner))
        path.addQuadCurve(
            to: CGPoint(x: maxX - keyCorner, y: height),
            controlPoint: CGPoint(x: maxX, y: height)
        )
        path.addLine(to: CGPoint(x: minX + keyCorner, y: height))
        path.addQuadCurve(
            to: CGPoint(x: minX, y: height - keyCorner),
            controlPoint: CGPoint(x: minX, y: height)
        )
        path.addLine(to: CGPoint(x: minX, y: balloonBottom + drop))
        path.addCurve(
            to: CGPoint(x: 0, y: balloonBottom - shoulder),
            controlPoint1: CGPoint(x: minX, y: balloonBottom - shoulder * 0.55),
            controlPoint2: CGPoint(x: 0, y: balloonBottom + drop * 0.55)
        )
        path.addLine(to: CGPoint(x: 0, y: corner))
        path.addQuadCurve(
            to: CGPoint(x: corner, y: 0),
            controlPoint: CGPoint(x: 0, y: 0)
        )
        path.close()
        return path
    }
}
