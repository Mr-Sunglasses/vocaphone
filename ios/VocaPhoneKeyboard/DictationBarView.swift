import UIKit

@MainActor
protocol DictationBarViewDelegate: AnyObject {
    func dictationBar(_ bar: DictationBarView, didTrigger action: DictationAction)
    /// The language and style pickers write straight to the shared preferences,
    /// so the controller only needs to know that a re-render is due.
    func dictationBarDidChangePreferences(_ bar: DictationBarView)
}

/// The dictation chrome above the keys: one container that morphs between
/// states rather than a fixed status card stacked on a fixed toolbar.
///
/// The two rows it replaces cost 117pt whether or not anything was happening.
/// This bar spends 72pt while idle and 84pt while a session is live, and the
/// difference goes to the keys.
final class DictationBarView: UIView {
    weak var delegate: (any DictationBarViewDelegate)?

    var metrics: DictationBarMetrics {
        didSet {
            guard metrics != oldValue else { return }
            applyMetrics()
        }
    }

    var palette: KeyboardPalette {
        didSet {
            guard palette != oldValue else { return }
            applyPalette()
        }
    }

    private let indicator = StatusIndicatorView()
    private let titleLabel = UILabel()
    private let timerLabel = UILabel()
    private let headlineStack = UIStackView()

    private let bodyContainer = UIView()
    private let controlsStack = UIStackView()
    private let languageButton = UIButton(type: .system)
    private let styleButton = UIButton(type: .system)
    private let waveform = WaveformView()
    private let messageLabel = UILabel()

    private let actionStack = UIStackView()
    private let secondaryStack = UIStackView()
    private let primaryButton = GradientButton()
    private var secondaryButtons: [UIButton] = []
    private var secondaryActions: [DictationAction] = []

    private var renderedModel: DictationBarModel?
    private var renderedLanguage: TranscriptionLanguage?
    private var renderedLanguageMenuKey: LanguageMenuKey?
    private var renderedStyle: WritingStyle?
    private var visibleBodyView: UIView?
    private var flashWork: DispatchWorkItem?
    private var isFlashing = false

    private var horizontalInsets: [NSLayoutConstraint] = []
    private var topInset: NSLayoutConstraint?
    private var bottomInset: NSLayoutConstraint?
    private var primaryWidthConstraint: NSLayoutConstraint?
    private var primaryHeightConstraint: NSLayoutConstraint?
    private var waveformHeightConstraint: NSLayoutConstraint?
    private var controlHeights: [NSLayoutConstraint] = []
    private var secondarySizes: [NSLayoutConstraint] = []

    private static let flashDuration: TimeInterval = 2.6
    /// Two is all the states ever ask for, so they are built once instead of
    /// being created and thrown away as the session moves.
    private static let secondaryCapacity = 2

    init(metrics: DictationBarMetrics, palette: KeyboardPalette) {
        self.metrics = metrics
        self.palette = palette
        super.init(frame: .zero)
        configureSubviews()
        configureLayout()
        applyMetrics()
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: metrics.cornerRadius
        ).cgPath
    }

    // MARK: - Rendering

    /// `render` runs on every poll tick, so an unchanged model must cost
    /// nothing: rebuilding button configurations four times a second churned
    /// allocations and re-laid out the whole bar for state that had not moved.
    func apply(_ model: DictationBarModel, animated: Bool) {
        defer { renderedModel = model }
        updatePreferenceControls()
        guard model != renderedModel else { return }
        let accentChanged = model.accent != renderedModel?.accent

        if titleLabel.text != model.title {
            crossfade(titleLabel, animated: animated) { self.titleLabel.text = model.title }
        }
        timerLabel.isHidden = !model.showsElapsedTime
        indicator.pulse = model.pulse
        if accentChanged {
            applyAccent(model.accent, animated: animated)
        }
        // A transient message holds the slot against repeated renders of the same
        // state, but never against a real change: "Starting with Quick
        // Dictation…" must not still be covering the meter once recording has
        // actually begun.
        if !isFlashing || model.body != renderedModel?.body {
            endFlash()
            setBody(model.body, animated: animated)
        }
        configurePrimary(model.primary, animated: animated)
        configureSecondaries(model.secondaries)
    }

    /// The most recent microphone level. Kept separate from `apply` because it
    /// changes on every tick while the model does not.
    func push(meterLevel: Float) {
        waveform.push(level: meterLevel)
    }

    func setElapsed(_ interval: TimeInterval?) {
        let text = interval.map { DictationBarModel.elapsedText($0) }
        guard timerLabel.text != text else { return }
        timerLabel.text = text
        timerLabel.accessibilityLabel = text.map { "Recording time \($0)" }
    }

    /// A message that outlives the next poll tick. Direct writes to the status
    /// label used to be erased a quarter of a second later, so the guidance the
    /// user needed most was the guidance they never got to read.
    func flash(_ message: String) {
        endFlash()
        isFlashing = true
        setBody(.message(message), animated: true)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            isFlashing = false
            if let body = renderedModel?.body { setBody(body, animated: true) }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashDuration, execute: work)
    }

    private func endFlash() {
        flashWork?.cancel()
        flashWork = nil
        isFlashing = false
    }

    // MARK: - Body

    private func setBody(_ body: DictationBody, animated: Bool) {
        if case let .message(text) = body, messageLabel.text != text {
            let sameView = visibleBodyView === messageLabel
            crossfade(messageLabel, animated: animated && sameView) {
                self.messageLabel.text = text
                self.messageLabel.accessibilityLabel = text
            }
        }
        if case let .waveform(mode) = body {
            waveform.mode = mode
        } else {
            waveform.mode = nil
        }

        let target: UIView = switch body {
        case .controls: controlsStack
        case .waveform: waveform
        case .message: messageLabel
        }
        guard target !== visibleBodyView else { return }
        let previous = visibleBodyView
        visibleBodyView = target
        target.isHidden = false
        guard animated else {
            target.alpha = 1
            previous?.alpha = 0
            previous?.isHidden = true
            return
        }
        UIView.animate(withDuration: 0.24, delay: 0, options: [.beginFromCurrentState]) {
            target.alpha = 1
            previous?.alpha = 0
        } completion: { _ in
            // A second change may have overtaken this animation.
            if previous !== self.visibleBodyView { previous?.isHidden = true }
        }
    }

    // MARK: - Buttons

    private func configurePrimary(_ button: DictationButton, animated: Bool) {
        let changed = renderedModel?.primary != button
        primaryButton.isEnabled = button.isEnabled
        primaryButton.accessibilityLabel = button.title
        primaryButton.accessibilityHint = button.hint
        guard changed || primaryButton.configuration == nil else { return }
        let titleSize = metrics.titleFontSize
        let update = { [primaryButton] in
            var configuration = UIButton.Configuration.plain()
            configuration.title = button.title
            configuration.image = UIImage(
                systemName: button.symbol,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: titleSize - 2,
                    weight: .semibold
                )
            )
            configuration.imagePadding = 6
            configuration.contentInsets = .zero
            configuration.baseForegroundColor = .white
            // UIKit dims a disabled button's own colours towards grey, which on
            // the muted fill left the label barely legible. The label and glyph
            // stay white in every state and the fill alone carries "disabled".
            configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in .white }
            configuration.titleTextAttributesTransformer =
                UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.font = .systemFont(ofSize: titleSize - 1, weight: .semibold)
                    outgoing.foregroundColor = UIColor.white
                    return outgoing
                }
            primaryButton.configuration = configuration
        }
        crossfade(primaryButton, animated: animated && changed, changes: update)
    }

    private func configureSecondaries(_ items: [DictationButton]) {
        guard items != renderedModel?.secondaries || secondaryActions.isEmpty else { return }
        secondaryActions = items.map(\.action)
        for (index, button) in secondaryButtons.enumerated() {
            guard index < items.count else {
                button.isHidden = true
                continue
            }
            let item = items[index]
            button.isHidden = false
            button.accessibilityLabel = item.title
            button.accessibilityHint = item.hint
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(
                systemName: item.symbol,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: metrics.bodyFontSize + 1,
                    weight: .semibold
                )
            )
            configuration.contentInsets = .zero
            configuration.cornerStyle = .capsule
            configuration.background.backgroundColor = palette.secondaryControl
            configuration.baseForegroundColor = palette.secondaryLabel
            button.configuration = configuration
        }
        secondaryStack.isHidden = items.isEmpty
    }

    @objc private func primaryTapped() {
        guard let action = renderedModel?.primary.action else { return }
        delegate?.dictationBar(self, didTrigger: action)
    }

    @objc private func secondaryTapped(_ sender: UIButton) {
        guard sender.tag < secondaryActions.count else { return }
        delegate?.dictationBar(self, didTrigger: secondaryActions[sender.tag])
    }

    // MARK: - Preference controls

    /// Everything the language menu is drawn from. The gateway's model can change
    /// without the selection changing, and that flips which entries are usable.
    struct LanguageMenuKey: Equatable {
        let selected: TranscriptionLanguage
        let modelLanguages: Set<String>
        let detectsLanguage: Bool
        let recents: [TranscriptionLanguage]

        static func current(selected: TranscriptionLanguage) -> LanguageMenuKey {
            LanguageMenuKey(
                selected: selected,
                modelLanguages: KeyboardPreferences.modelLanguages,
                detectsLanguage: KeyboardPreferences.modelDetectsLanguage,
                recents: KeyboardPreferences.recentTranscriptionLanguages
            )
        }
    }

    /// Automatic, then a few recent languages, then everything else behind a
    /// submenu. A flat list of 27 was unusable on a surface this cramped; this
    /// keeps the top level to about five rows however many languages exist.
    func makeLanguageMenu(
        selected: TranscriptionLanguage,
        key: LanguageMenuKey
    ) -> UIMenu {
        func action(for option: TranscriptionLanguage) -> UIAction {
            let selectable = ModelLanguageSupport.isSelectable(
                option,
                modelLanguages: key.modelLanguages,
                detectsLanguageAutomatically: key.detectsLanguage
            )
            let action = UIAction(
                title: option.displayName,
                image: UIImage(systemName: "globe"),
                state: option == selected ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                KeyboardPreferences.transcriptionLanguage = option
                KeyboardPreferences.noteTranscriptionLanguageUse(option)
                delegate?.dictationBarDidChangePreferences(self)
            }
            if !selectable { action.attributes = .disabled }
            return action
        }

        // Only usable recents are promoted: a greyed-out shortcut is worse than
        // no shortcut, because it occupies one of very few visible rows.
        let recents = key.recents.filter { option in
            option != .automatic
                && ModelLanguageSupport.isSelectable(
                    option,
                    modelLanguages: key.modelLanguages,
                    detectsLanguageAutomatically: key.detectsLanguage
                )
        }
        var shortcuts = [action(for: .automatic)]
        shortcuts.append(contentsOf: recents.map(action(for:)))
        // The selection itself always deserves a row, even if it was never
        // recorded as recent — it is the one entry the user is looking for.
        if selected != .automatic, !recents.contains(selected) {
            shortcuts.append(action(for: selected))
        }

        let remaining = TranscriptionLanguage.allCases.filter { option in
            !shortcuts.contains { $0.title == option.displayName }
        }
        var children: [UIMenuElement] = [
            UIMenu(title: "", options: .displayInline, children: shortcuts)
        ]
        if !remaining.isEmpty {
            children.append(
                UIMenu(
                    title: "All languages",
                    image: UIImage(systemName: "list.bullet"),
                    children: remaining.map(action(for:))
                )
            )
        }
        return UIMenu(title: "Transcription language", children: children)
    }

    private func updatePreferenceControls() {
        // The effective language, not the stored one. A stored choice the loaded
        // model cannot honour is dictated as Automatic, and a chip reading "HI"
        // while Automatic is what happens is the UI lying about the result. The
        // stored preference is untouched and returns when a model supports it.
        let language = KeyboardPreferences.effectiveTranscriptionLanguage
        let menuKey = LanguageMenuKey.current(selected: language)
        // Keyed on everything the menu draws from, not just the selection. Keying
        // on the language alone left the enabled states stale after the gateway
        // switched models, so the keyboard kept offering languages the app had
        // already ruled out.
        if renderedLanguageMenuKey != menuKey {
            renderedLanguageMenuKey = menuKey
            renderedLanguage = language
            languageButton.menu = makeLanguageMenu(selected: language, key: menuKey)
            applyChipConfiguration(
                to: languageButton,
                title: language.shortLabel,
                symbol: "globe"
            )
            languageButton.accessibilityValue = language.displayName
        }

        let style = KeyboardPreferences.writingStyle
        guard renderedStyle != style else { return }
        renderedStyle = style
        styleButton.menu = UIMenu(
            title: "Writing style",
            children: WritingStyle.allCases.map { option in
                UIAction(
                    title: option.displayName,
                    image: UIImage(systemName: option.symbolName),
                    state: option == style ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    KeyboardPreferences.writingStyle = option
                    delegate?.dictationBarDidChangePreferences(self)
                }
            }
        )
        applyChipConfiguration(
            to: styleButton,
            title: style.displayName,
            symbol: style.symbolName
        )
        styleButton.accessibilityValue = style.displayName
    }

    private func applyChipConfiguration(to button: UIButton, title: String, symbol: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: metrics.bodyFontSize - 0.5,
                weight: .semibold
            )
        )
        configuration.imagePadding = 5
        configuration.cornerStyle = .capsule
        configuration.titleLineBreakMode = .byTruncatingTail
        // The chevron says these open a menu, which the old flat pills did not.
        configuration.indicator = .popup
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: 8,
            bottom: 0,
            trailing: 6
        )
        configuration.background.backgroundColor = palette.chipBackground
        configuration.baseForegroundColor = palette.tint(for: .brand)
        let titleSize = metrics.bodyFontSize
        configuration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: titleSize, weight: .semibold)
                return outgoing
            }
        button.configuration = configuration
    }

    // MARK: - Appearance

    /// The colour change is what carries a state transition, so it is animated
    /// at the layer level rather than through a whole-bar dissolve, which would
    /// have fought the label and button transitions running at the same time.
    private func applyAccent(_ accent: DictationAccent, animated: Bool) {
        let tint = palette.tint(for: accent)
        // Standalone sublayers animate their colour implicitly; the bar's own
        // backing layer does not, so its border is animated by hand.
        primaryButton.fillColors = palette.gradient(for: accent)
        indicator.color = tint
        waveform.color = tint
        crossfade(timerLabel, animated: animated) { self.timerLabel.textColor = tint }

        // A live session tints the outline; at rest the bar keeps the neutral
        // border the keys sit inside.
        let border = accent == .brand
            ? palette.cardBorder.cgColor
            : tint.withAlphaComponent(0.3).cgColor
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            layer.borderColor = border
            return
        }
        let fade = CABasicAnimation(keyPath: "borderColor")
        fade.fromValue = layer.borderColor
        fade.toValue = border
        fade.duration = 0.24
        layer.borderColor = border
        layer.add(fade, forKey: "vocaphone.border")
    }

    private func applyPalette() {
        backgroundColor = palette.barBackground
        layer.borderColor = palette.cardBorder.cgColor
        titleLabel.textColor = palette.label
        messageLabel.textColor = palette.secondaryLabel
        // Colours are baked into the button configurations, so every cached
        // rendering has to be discarded before the next apply.
        renderedModel = nil
        renderedLanguage = nil
        renderedLanguageMenuKey = nil
        renderedStyle = nil
    }

    private func applyMetrics() {
        for constraint in horizontalInsets {
            constraint.constant = constraint.firstAttribute == .leading
                ? metrics.horizontalInset
                : -metrics.horizontalInset
        }
        topInset?.constant = metrics.verticalInset
        bottomInset?.constant = -metrics.verticalInset
        primaryWidthConstraint?.constant = metrics.primaryWidth
        primaryHeightConstraint?.constant = metrics.primaryHeight
        waveformHeightConstraint?.constant = metrics.waveformHeight
        controlHeights.forEach { $0.constant = metrics.controlHeight }
        secondarySizes.forEach { $0.constant = metrics.secondaryDiameter }

        layer.cornerRadius = metrics.cornerRadius
        titleLabel.font = .systemFont(ofSize: metrics.titleFontSize, weight: .semibold)
        timerLabel.font = .monospacedDigitSystemFont(
            ofSize: metrics.titleFontSize - 2,
            weight: .medium
        )
        messageLabel.font = .systemFont(ofSize: metrics.bodyFontSize, weight: .regular)
        messageLabel.numberOfLines = metrics.messageLineLimit
        renderedModel = nil
        renderedLanguage = nil
        renderedLanguageMenuKey = nil
        renderedStyle = nil
        setNeedsLayout()
    }

    /// Colour and label changes snapping between states is what made the old
    /// card feel mechanical; every one of them dissolves instead.
    private func crossfade(_ view: UIView, animated: Bool, changes: @escaping () -> Void) {
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        UIView.transition(
            with: view,
            duration: 0.22,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
            animations: changes
        )
    }

    // MARK: - Construction

    private func configureSubviews() {
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.07
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)

        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timerLabel.setContentHuggingPriority(.required, for: .horizontal)
        timerLabel.isHidden = true

        headlineStack.axis = .horizontal
        headlineStack.alignment = .center
        headlineStack.spacing = 6
        [indicator, titleLabel, timerLabel].forEach(headlineStack.addArrangedSubview)

        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.isAccessibilityElement = true
        // Two lines of transcript preview must not spill over the keys below.
        bodyContainer.clipsToBounds = true

        languageButton.showsMenuAsPrimaryAction = true
        languageButton.accessibilityLabel = "Transcription language"
        styleButton.showsMenuAsPrimaryAction = true
        styleButton.accessibilityLabel = "Writing style"
        controlsStack.axis = .horizontal
        controlsStack.alignment = .center
        controlsStack.spacing = 5
        [languageButton, styleButton].forEach(controlsStack.addArrangedSubview)
        [languageButton, styleButton].forEach {
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        // A chip squeezed even a point below its natural width used to wrap its
        // title onto a second line. The language label is short enough to always
        // hold its ground; the longest style name gives way and truncates, which
        // only happens in the one state that also offers Undo.
        languageButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        styleButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // Only one body view is visible at a time; the others stay in place at
        // zero alpha so a change is a dissolve rather than a re-layout.
        for view in [controlsStack, waveform, messageLabel] as [UIView] {
            view.alpha = 0
            view.isHidden = true
            bodyContainer.addSubview(view)
        }

        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        secondaryStack.axis = .horizontal
        secondaryStack.alignment = .center
        secondaryStack.spacing = 6
        for index in 0..<Self.secondaryCapacity {
            let button = UIButton(type: .system)
            button.tag = index
            button.isHidden = true
            button.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
            secondaryButtons.append(button)
            secondaryStack.addArrangedSubview(button)
        }
        actionStack.axis = .horizontal
        actionStack.alignment = .center
        actionStack.spacing = 6
        [secondaryStack, primaryButton].forEach(actionStack.addArrangedSubview)

        [headlineStack, bodyContainer, actionStack].forEach(addSubview)
    }

    private func configureLayout() {
        [headlineStack, bodyContainer, actionStack, controlsStack, waveform, messageLabel]
            .forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let headlineLeading = headlineStack.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: metrics.horizontalInset
        )
        let bodyLeading = bodyContainer.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: metrics.horizontalInset
        )
        let actionTrailing = actionStack.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -metrics.horizontalInset
        )
        horizontalInsets = [headlineLeading, bodyLeading, actionTrailing]

        let top = headlineStack.topAnchor.constraint(
            equalTo: topAnchor,
            constant: metrics.verticalInset
        )
        let bottom = bodyContainer.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -metrics.verticalInset
        )
        topInset = top
        bottomInset = bottom

        let width = primaryButton.widthAnchor.constraint(equalToConstant: metrics.primaryWidth)
        let height = primaryButton.heightAnchor.constraint(equalToConstant: metrics.primaryHeight)
        primaryWidthConstraint = width
        primaryHeightConstraint = height

        let controlsTrailing = controlsStack.trailingAnchor.constraint(
            lessThanOrEqualTo: bodyContainer.trailingAnchor
        )

        let meter = waveform.heightAnchor.constraint(equalToConstant: metrics.waveformHeight)
        // The bar's own height is fixed from outside, so the meter yields rather
        // than breaking the layout when the two disagree.
        meter.priority = .defaultHigh
        waveformHeightConstraint = meter

        controlHeights = [languageButton, styleButton].map {
            let constraint = $0.heightAnchor.constraint(equalToConstant: metrics.controlHeight)
            constraint.priority = .defaultHigh
            return constraint
        }
        secondarySizes = secondaryButtons.flatMap { button in
            [
                button.widthAnchor.constraint(equalToConstant: metrics.secondaryDiameter),
                button.heightAnchor.constraint(equalToConstant: metrics.secondaryDiameter),
            ]
        }

        NSLayoutConstraint.activate([
            headlineLeading,
            top,
            headlineStack.trailingAnchor.constraint(
                lessThanOrEqualTo: actionStack.leadingAnchor,
                constant: -10
            ),
            bodyLeading,
            bottom,
            bodyContainer.topAnchor.constraint(equalTo: headlineStack.bottomAnchor, constant: 4),
            bodyContainer.trailingAnchor.constraint(
                equalTo: actionStack.leadingAnchor,
                constant: -10
            ),
            actionTrailing,
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            width,
            height,
            meter,
            waveform.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            waveform.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            waveform.centerYAnchor.constraint(equalTo: bodyContainer.centerYAnchor),
            waveform.heightAnchor.constraint(lessThanOrEqualTo: bodyContainer.heightAnchor),
            controlsStack.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            controlsStack.centerYAnchor.constraint(equalTo: bodyContainer.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: bodyContainer.centerYAnchor),
            controlsTrailing,
        ] + controlHeights + secondarySizes)
    }
}
