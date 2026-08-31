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
            applyColors(animated: !isHighlighted)
        }
    }

    /// Whether this key does anything when pressed. Only Return uses it, for
    /// the fields that set `enablesReturnKeyAutomatically` and expect the key to
    /// sit dimmed until there is something to send.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            applyColors()
            accessibilityTraits = isEnabled
                ? .keyboardKey
                : [.keyboardKey, .notEnabled]
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

        // A blank is a hole in the grid, not a control: it takes no touch, so it
        // must not be somewhere VoiceOver can land either.
        isAccessibilityElement = spec.cap.isInteractive
        accessibilityTraits = .keyboardKey
        if !spec.cap.isInteractive {
            layer.shadowOpacity = 0
        }
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
        case .blank:
            titleLabel.text = nil
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

    /// The style this key is actually drawn in right now.
    ///
    /// An active Shift is drawn on the *standard* key surface rather than the
    /// function one. That is the system keyboard's own behaviour and the reason
    /// it is legible at a glance: the filled glyph alone is a small difference
    /// to spot mid-sentence, and the lifted surface is what says "the next
    /// letter is a capital" without being read.
    ///
    /// The brand accent stays out of it. A mint Shift made the resting keyboard
    /// look like something was running.
    private var renderedStyle: KeyStyle {
        guard spec.cap == .shift, shift.isUppercase else { return spec.style }
        return .standard
    }

    private func applyColors(animated: Bool = false) {
        let style = renderedStyle
        let background = isHighlighted
            ? palette.pressedBackground(for: style)
            : palette.background(for: style)
        let foreground = palette.foreground(for: style)
        let apply = {
            self.backgroundColor = self.spec.cap.isInteractive ? background : .clear
            self.titleLabel.textColor = foreground
            self.symbolView.tintColor = foreground
            // Dimmed rather than hidden: a Return that vanishes when the field
            // is empty is a keyboard that has lost a key.
            self.alpha = self.isEnabled ? 1 : 0.4
        }
        // Pressing is instant — the finger is already there and any delay reads
        // as lag. Releasing fades, because the system keyboard's key settles
        // back rather than snapping, and an instant restore under a fast typist
        // is a strobe.
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.animate(
            withDuration: 0.11,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: apply
        )
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

    /// Grows the balloon out of the key it belongs to.
    ///
    /// The system keyboard's preview does not simply exist: it swells from the
    /// key under the finger in about a frame and a half. Appearing fully formed
    /// is the single clearest tell that a keyboard is not the system one — it
    /// reads as a tooltip rather than as the key itself lifting — and it costs
    /// one short animation to fix.
    ///
    /// The anchor is the bottom of the view, which is the bottom of the *key*,
    /// so the growth runs upward out of what the finger is covering.
    func appear(animated: Bool) {
        layer.removeAllAnimations()
        isHidden = false
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            alpha = 1
            transform = .identity
            return
        }
        alpha = 0
        transform = Self.growth(from: 0.82, 0.62, in: bounds)
        UIView.animate(
            withDuration: 0.09,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    /// Settles the balloon back into the key and hands the view back.
    ///
    /// `completion` runs whether or not the fade finished, so a pooled preview
    /// is never left half-transparent for the next keystroke to dequeue.
    func disappear(animated: Bool, completion: @escaping () -> Void) {
        layer.removeAllAnimations()
        let finish = {
            self.isHidden = true
            self.alpha = 1
            self.transform = .identity
            completion()
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            finish()
            return
        }
        UIView.animate(
            withDuration: 0.08,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.alpha = 0
            self.transform = Self.growth(from: 0.9, 0.75, in: self.bounds)
        } completion: { _ in
            finish()
        }
    }

    /// A scale about the view's *bottom* edge, expressed as an ordinary
    /// transform.
    ///
    /// The bottom of this view is the bottom of the key, so scaling there is
    /// what makes the balloon look like it grew out of what the finger is
    /// covering. Done with a translation rather than by moving `layer.anchorPoint`
    /// — an anchor point that is not the centre silently changes what setting
    /// `frame` means, and this view's frame is rewritten on every slide between
    /// keys.
    private static func growth(from scaleX: CGFloat, _ scaleY: CGFloat, in bounds: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: 0, y: bounds.height * (1 - scaleY) / 2)
            .scaledBy(x: scaleX, y: scaleY)
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
