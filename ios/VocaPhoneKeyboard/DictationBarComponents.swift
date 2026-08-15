import UIKit

/// A scrolling level meter. Replaces the fixed decorative pattern that used to
/// be scaled by a single number, which moved identically whether the user was
/// whispering or shouting.
///
/// Bars enter at the trailing edge and slide out of the leading one, so the view
/// shows the last few seconds of speech rather than one instant of it.
final class WaveformView: UIView {
    /// `nil` puts the view to sleep: no display link, no redraws. Ordinary
    /// typing is the common case and it must not pay for animation.
    var mode: WaveformMode? {
        didSet {
            guard mode != oldValue else { return }
            if mode == .indeterminate { phase = -0.25 }
            updateAnimation()
            setNeedsDisplay()
        }
    }

    var color: UIColor = BrandPalette.accent {
        didSet { setNeedsDisplay() }
    }

    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 2.5
    /// New bars per second. Slow enough to read as speech, fast enough that a
    /// short utterance still fills the view.
    private static let barsPerSecond: CGFloat = 14

    private var levels: [CGFloat] = []
    private var smoothedLevel: CGFloat = 0
    private var targetLevel: CGFloat = 0
    private var advanceProgress: CGFloat = 0
    private var phase: CGFloat = -0.25
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        // Bars leave through the leading edge rather than drawing over the
        // status indicator beside them.
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Voice level"
        accessibilityTraits = [.updatesFrequently]
        updateAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The newest microphone level, published by the app roughly four times a
    /// second. Rendering interpolates between these so the meter does not step.
    func push(level: Float) {
        targetLevel = min(max(CGFloat(level), 0), 1)
        updateAccessibilityValue()
        // Reduce Motion, an offscreen keyboard, anything that stops the display
        // link: with nothing else advancing the meter, each published level has
        // to become a bar itself rather than leaving a frozen line.
        guard displayLink == nil, mode == .live else { return }
        smoothedLevel = targetLevel
        appendBar(smoothedLevel)
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        resizeBuffer()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()
    }

    override func draw(_ rect: CGRect) {
        guard !levels.isEmpty, bounds.height > 0 else { return }
        let step = Self.barWidth + Self.barGap
        let offset = mode == .indeterminate ? 0 : advanceProgress * step
        let radius = Self.barWidth / 2

        for (index, stored) in levels.enumerated() {
            let value = mode == .indeterminate ? pulseValue(at: index) : stored
            let height = max(Self.barWidth, value * bounds.height)
            let bar = CGRect(
                x: CGFloat(index) * step - offset,
                y: bounds.midY - height / 2,
                width: Self.barWidth,
                height: height
            )
            color.withAlphaComponent(alpha(at: index)).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: radius).fill()
        }
    }

    // MARK: - Rendering values

    /// Older bars fade out, which gives the meter a direction of travel without
    /// adding another visual layer.
    private func alpha(at index: Int) -> CGFloat {
        guard mode != .indeterminate else { return 0.85 }
        let position = CGFloat(index) / CGFloat(max(levels.count - 1, 1))
        return 0.24 + 0.76 * position
    }

    /// A soft bump travelling from the leading edge to the trailing one. Shaped
    /// deliberately unlike speech so a wait is never read as recorded audio.
    private func pulseValue(at index: Int) -> CGFloat {
        let position = CGFloat(index) / CGFloat(max(levels.count - 1, 1))
        let distance = (position - phase) / 0.16
        return 0.1 + 0.8 * exp(-distance * distance)
    }

    private func appendBar(_ value: CGFloat) {
        guard !levels.isEmpty else { return }
        levels.removeFirst()
        levels.append(value)
    }

    private func resizeBuffer() {
        let step = Self.barWidth + Self.barGap
        // One extra bar covers the slot that is part-way through scrolling in.
        let count = max(0, Int(((bounds.width + step) / step).rounded(.down)))
        guard count != levels.count else { return }
        if count < levels.count {
            levels.removeFirst(levels.count - count)
        } else {
            levels.insert(contentsOf: [CGFloat](repeating: 0, count: count - levels.count), at: 0)
        }
    }

    // MARK: - Animation

    private var reduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// A display link retains its target and is itself retained by the run
    /// loop, so leaving the window has to tear it down; there is no `deinit`
    /// that could reach it once the cycle exists.
    private func updateAnimation() {
        let wantsLink = mode != nil && window != nil && !reduceMotion
        guard wantsLink else {
            displayLink?.invalidate()
            displayLink = nil
            if mode == nil {
                levels = levels.map { _ in 0 }
                smoothedLevel = 0
                advanceProgress = 0
            }
            return
        }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        // Half the usual rate is plenty for bars this narrow, and a keyboard
        // extension has little headroom to spare.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        switch mode {
        case .live:
            smoothedLevel += (targetLevel - smoothedLevel) * 0.3
            advanceProgress += Self.barsPerSecond * CGFloat(elapsed)
            while advanceProgress >= 1 {
                advanceProgress -= 1
                appendBar(smoothedLevel)
            }
        case .indeterminate:
            phase += CGFloat(elapsed) * 0.75
            if phase > 1.25 { phase = -0.25 }
        case nil:
            return
        }
        setNeedsDisplay()
    }

    private func updateAccessibilityValue() {
        switch mode {
        case .live: accessibilityValue = "\(Int(targetLevel * 100)) percent"
        case .indeterminate: accessibilityValue = "Working"
        case nil: accessibilityValue = "Not recording"
        }
    }
}

/// The dot beside the status title. Small, but it is the only element that keeps
/// moving while the user waits, so it carries the "still alive" signal.
final class StatusIndicatorView: UIView {
    var pulse: DictationPulse = .steady {
        didSet {
            guard pulse != oldValue else { return }
            applyAnimation()
        }
    }

    var color: UIColor = BrandPalette.accent {
        didSet {
            core.backgroundColor = color.cgColor
            ring.borderColor = color.cgColor
        }
    }

    private let core = CALayer()
    private let ring = CALayer()
    private static let coreDiameter: CGFloat = 9

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        ring.borderWidth = 1.5
        ring.opacity = 0
        layer.addSublayer(ring)
        layer.addSublayer(core)
        color = BrandPalette.accent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 22, height: 22)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = Self.coreDiameter
        let rect = CGRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
        // Frame changes would otherwise animate implicitly and fight the pulse.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        core.frame = rect
        core.cornerRadius = size / 2
        ring.frame = rect
        ring.cornerRadius = size / 2
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyAnimation()
    }

    private func applyAnimation() {
        core.removeAllAnimations()
        ring.removeAllAnimations()
        ring.opacity = 0
        core.transform = CATransform3DIdentity
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { return }

        switch pulse {
        case .steady:
            return
        case .listening:
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 2.7
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.5
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.5
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(group, forKey: "vocaphone.ring")
        case .working:
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.78
            breathe.toValue = 1.18
            breathe.duration = 0.7
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            core.add(breathe, forKey: "vocaphone.breathe")
        }
    }
}

/// The bar's primary action uses a solid fill and quiet press feedback.
final class FlatButton: UIButton {
    var fillColor: UIColor = BrandPalette.accent {
        didSet { applyFill() }
    }

    override var isEnabled: Bool {
        didSet { applyFill() }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let collapse = isHighlighted
            UIView.animate(
                withDuration: collapse ? 0.09 : 0.22,
                delay: 0,
                usingSpringWithDamping: 0.7,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.transform = collapse
                    ? CGAffineTransform(scaleX: 0.955, y: 0.955)
                    : .identity
            }
        }
    }

    init() {
        super.init(frame: .zero)
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: bounds.height / 2
        ).cgPath
    }

    private func applyFill() {
        backgroundColor = isEnabled
            ? fillColor
            : fillColor.withAlphaComponent(KeyboardPalette.disabledFillAlpha)
        layer.shadowColor = fillColor.cgColor
        layer.shadowOpacity = isEnabled ? 0.16 : 0
    }
}
