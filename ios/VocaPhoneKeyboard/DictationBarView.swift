import UIKit

@MainActor
protocol DictationBarViewDelegate: AnyObject {
    func dictationBar(_ bar: DictationBarView, didTrigger action: DictationAction)
    /// The language and style pickers write straight to the shared preferences,
    /// so the controller only needs to know that a re-render is due.
    func dictationBarDidChangePreferences(_ bar: DictationBarView)
    /// A candidate chip was tapped.
    func dictationBar(_ bar: DictationBarView, didChoose candidate: TypingCandidate)
}

/// The dictation chrome above the keys: one container that morphs between
/// states rather than a fixed status card stacked on a fixed toolbar.
///
/// The two rows it replaces cost 117pt whether or not anything was happening.
/// This bar spends 72pt while idle and 84pt while a session is live, and the
/// difference goes to the keys.
final class DictationBarView: UIView, TypingStripViewDelegate {
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
    private lazy var typingStrip = TypingStripView(palette: palette, metrics: metrics)

    private let actionStack = UIStackView()
    private let secondaryStack = UIStackView()
    private let primaryButton = FlatButton()
    private var secondaryButtons: [UIButton] = []
    private var secondaryActions: [DictationAction] = []

    private var renderedModel: DictationBarModel?
    private var renderedLanguage: TranscriptionLanguage?
    private var renderedLanguageMenuKey: LanguageMenuKey?
    private var renderedStyle: WritingStyle?
    private var visibleBodyView: UIView?
    private var renderedLayout: DictationBarLayout?
    /// Set from layout, not from traits: both a 320pt and a 430pt phone are
    /// compact-width, and only one of them is short of room.
    private var isNarrow = false
    private var flashWork: DispatchWorkItem?
    private var isFlashing = false

    private var horizontalInsets: [NSLayoutConstraint] = []
    private var topInset: NSLayoutConstraint?
    private var bottomInset: NSLayoutConstraint?
    private var primaryWidthConstraint: NSLayoutConstraint?
    private var bodyTopConstraint: NSLayoutConstraint?
    private var bodyTopToBarConstraint: NSLayoutConstraint?
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
        applyWidthAdjustment()
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: metrics.cornerRadius
        ).cgPath
    }

    /// Gives the title back some of the action column on a narrow phone.
    ///
    /// The metrics are resolved from traits, which cannot tell a 320pt phone
    /// from a 430pt one — both are compact-width. With a fixed 116pt button and
    /// a 34pt secondary, "Gateway unavailable" had about 80pt to live in at
    /// 320pt and truncated to "Gateway una…", which names no problem at all.
    /// The controls shrink instead, down to a floor that keeps the primary a
    /// comfortable target.
    private func applyWidthAdjustment() {
        guard bounds.width > 0 else { return }
        // The strip's button is a circle sized from the row, not from the
        // available width; narrowing it would make it an ellipse.
        guard renderedLayout != .strip else { return }
        // A 393pt phone, less the keyboard's own side insets: the width the
        // metrics were chosen against.
        let reference: CGFloat = 381
        let scale = min(1, max(0.82, bounds.width / reference))
        let width = (metrics.primaryWidth * scale).rounded()
        let diameter = (metrics.secondaryDiameter * scale).rounded()
        // On the narrowest phone the primary drops its glyph as well. The label
        // is the promise the button makes; the icon only decorates it, and 26pt
        // of decoration is the difference between "Gateway unavailable" and
        // "Gateway unavaila…".
        let narrow = bounds.width < 340
        if narrow != isNarrow {
            isNarrow = narrow
            if let model = renderedModel {
                configurePrimary(
                    model.primary,
                    accent: model.accent,
                    animated: false,
                    force: true
                )
            }
        }
        // Constraint writes re-enter layout, so only a real change may go
        // through.
        guard primaryWidthConstraint?.constant != width else { return }
        primaryWidthConstraint?.constant = width
        secondarySizes.forEach { $0.constant = diameter }
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
        applyLayout(model.layout)
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
        configurePrimary(model.primary, accent: model.accent, animated: animated)
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

    /// Switches between the one-row strip and the headline-and-body pair.
    ///
    /// The strip has no headline at all: the chips are the content, the round
    /// button says what it does, and a "Ready to dictate" title above them would
    /// be a row of chrome bought with the height the strip exists to save.
    private func applyLayout(_ layout: DictationBarLayout) {
        guard layout != renderedLayout else { return }
        renderedLayout = layout
        let isStrip = layout == .strip
        headlineStack.isHidden = isStrip
        bodyTopConstraint?.isActive = !isStrip
        bodyTopToBarConstraint?.isActive = isStrip
        // A configuration built for the other layout carries the wrong shape, so
        // both buttons are rebuilt on the next apply.
        renderedModel = nil
        applyMetrics()
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
        if case let .candidates(candidates) = body {
            typingStrip.apply(candidates, animated: animated)
        }

        let target: UIView = switch body {
        case .controls: controlsStack
        case .candidates: typingStrip
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

    /// The accent is part of the configuration, not just of the fill: the label
    /// has to be dark on a light accent and light on a dark one, so an
    /// accent-only change still has to rebuild this.
    private func configurePrimary(
        _ button: DictationButton,
        accent: DictationAccent,
        animated: Bool,
        force: Bool = false
    ) {
        let changed = force
            || renderedModel?.primary != button
            || renderedModel?.accent != accent
        primaryButton.isEnabled = button.isEnabled
        primaryButton.accessibilityLabel = button.title
        primaryButton.accessibilityHint = button.hint
        guard changed || primaryButton.configuration == nil else { return }
        let titleSize = metrics.titleFontSize
        // The strip's Dictate button is a circle with a microphone in it. The
        // word "Dictate" is worth 70 pt of a row whose whole purpose is to show
        // candidates, and the glyph plus the accessibility label say the same
        // thing in none of it.
        let isCompact = renderedLayout == .strip
        let showsGlyph = !isNarrow || isCompact
        let showsTitle = !isCompact
        let labelColor = palette.labelColor(for: accent, enabled: button.isEnabled)
        let update = { [primaryButton] in
            var configuration = UIButton.Configuration.plain()
            configuration.title = showsTitle ? button.title : nil
            configuration.image = showsGlyph
                ? UIImage(
                    systemName: button.symbol,
                    withConfiguration: UIImage.SymbolConfiguration(
                        pointSize: titleSize - 2,
                        weight: .semibold
                    )
                )
                : nil
            configuration.imagePadding = showsGlyph && showsTitle ? 6 : 0
            configuration.contentInsets = .zero
            configuration.baseForegroundColor = labelColor
            // UIKit dims a disabled button's own colours towards grey, which on
            // the muted fill left the label barely legible. The label and glyph
            // keep their colour in every state and the fill alone carries
            // "disabled".
            configuration.imageColorTransformer =
                UIConfigurationColorTransformer { _ in labelColor }
            configuration.titleTextAttributesTransformer =
                UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.font = .systemFont(ofSize: titleSize - 1, weight: .semibold)
                    outgoing.foregroundColor = labelColor
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

    /// Chip taps travel straight through: the bar draws the strip, but only the
    /// controller can rewrite the document.
    func typingStrip(_ strip: TypingStripView, didChoose candidate: TypingCandidate) {
        delegate?.dictationBar(self, didChoose: candidate)
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
        let recents: [TranscriptionLanguage]

        static func current(selected: TranscriptionLanguage) -> LanguageMenuKey {
            LanguageMenuKey(
                selected: selected,
                modelLanguages: KeyboardPreferences.activeModelLanguages,
                recents: KeyboardPreferences.recentTranscriptionLanguages
            )
        }
    }

    /// Automatic, then a few recent languages, then everything else behind a
    /// submenu. A flat list of every language was unusable on a surface this
    /// cramped; this keeps the top level to about five rows however many
    /// languages exist.
    func makeLanguageMenu(
        selected: TranscriptionLanguage,
        key: LanguageMenuKey
    ) -> UIMenu {
        func action(for option: TranscriptionLanguage) -> UIAction {
            let selectable = ModelLanguageSupport.isSelectable(
                option,
                modelLanguages: key.modelLanguages
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
                    modelLanguages: key.modelLanguages
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
        primaryButton.fillColor = tint
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
        // The strip is a child view with its own copy of the palette, and it
        // was never told when the keyboard changed appearance — so in a dark
        // field it kept drawing the light palette's black chip labels on a dark
        // bar, which is to say it drew nothing anyone could read.
        typingStrip.palette = palette
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
        let isStrip = renderedLayout == .strip
        primaryWidthConstraint?.constant = isStrip
            ? metrics.chipHeight
            : metrics.primaryWidth
        primaryHeightConstraint?.constant = isStrip
            ? metrics.chipHeight
            : metrics.primaryHeight
        bodyTopToBarConstraint?.constant = metrics.verticalInset
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
        typingStrip.metrics = metrics
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
        // A state name shrunk by a quarter is still readable; a state name cut
        // to "Gateway una…" names no problem at all. Shrinking is the better of
        // the two failures, and it only engages on the narrowest phones — at
        // 393pt the longest title renders at full size.
        titleLabel.minimumScaleFactor = 0.72
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

        typingStrip.chipDelegate = self

        // Only one body view is visible at a time; the others stay in place at
        // zero alpha so a change is a dissolve rather than a re-layout.
        for view in [controlsStack, waveform, messageLabel, typingStrip] as [UIView] {
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
        [
            headlineStack, bodyContainer, actionStack, controlsStack, waveform,
            messageLabel, typingStrip,
        ].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

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

        // In `status` the body hangs off the headline; in `strip` there is no
        // headline, so it takes the whole row.
        let bodyBelowHeadline = bodyContainer.topAnchor.constraint(
            equalTo: headlineStack.bottomAnchor,
            constant: 4
        )
        let bodyFillsBar = bodyContainer.topAnchor.constraint(
            equalTo: topAnchor,
            constant: metrics.verticalInset
        )
        bodyBelowHeadline.isActive = true
        bodyTopConstraint = bodyBelowHeadline
        bodyTopToBarConstraint = bodyFillsBar

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
            typingStrip.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            typingStrip.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            typingStrip.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            typingStrip.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            controlsTrailing,
        ] + controlHeights + secondarySizes)
    }
}

#if DEBUG
import SwiftUI

// MARK: - Previews

// The bar is one control that becomes eight different things. `DictationBarModel`
// is pure and already tested, but what the model turns into on screen — the
// accent, the pulse, which secondaries fit, how the strip and status layouts
// differ — had only ever been seen in the two or three states that are easy to
// reach from a host app.

private struct DictationBarPreview: View {
    var context: DictationContext
    var dark = false
    var preference: KeyboardHeightPreference = .standard

    var body: some View {
        let metrics = KeyboardPreviewEnvironment.barMetrics(preference)
        let palette = KeyboardPreviewEnvironment.palette(dark: dark)
        return KeyboardViewPreview {
            DictationBarView(metrics: metrics, palette: palette)
        } configure: { bar in
            bar.metrics = metrics
            bar.palette = palette
            bar.apply(DictationBarModel.make(context), animated: false)
        }
        .frame(width: 360, height: metrics.stripHeight)
        .background(Color(palette.background))
    }
}

private struct DictationBarGallery: View {
    var dark = false

    private var states: [(String, DictationContext)] {
        [
            (
                "Idle, suggestions",
                DictationContext(
                    state: .idle,
                    candidates: KeyboardPreviewEnvironment.candidates
                )
            ),
            ("Idle, no suggestions", DictationContext(state: .idle)),
            (
                "No Full Access",
                DictationContext(state: .idle, hasFullAccess: false)
            ),
            ("Opening vocaphone", DictationContext(state: .launchingApp)),
            ("Recording", DictationContext(state: .recording)),
            (
                "Transcribing on the gateway",
                DictationContext(state: .transcribing, processingLocation: .gateway)
            ),
            (
                "Transcribing on this iPhone",
                DictationContext(state: .transcribing, processingLocation: .onDevice)
            ),
            (
                "Ready to insert",
                DictationContext(
                    state: .readyToInsert,
                    transcript: "Let's move the review to Thursday afternoon."
                )
            ),
            (
                "Field changed while transcribing",
                DictationContext(
                    state: .targetContextChanged,
                    transcript: "Let's move the review to Thursday afternoon."
                )
            ),
            (
                "Inserted, undo available",
                DictationContext(state: .inserted, canUndo: true)
            ),
            (
                "Gateway unavailable, can retry",
                DictationContext(
                    state: .serverUnavailable,
                    errorMessage: "Your gateway did not answer. The recording is kept.",
                    canRetry: true
                )
            ),
            (
                "Transcription failed for good",
                DictationContext(
                    state: .transcriptionFailedPermanent,
                    errorMessage: "No text came back for this recording."
                )
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(states, id: \.0) { name, context in
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                DictationBarPreview(context: context, dark: dark)
            }
        }
        .padding()
    }
}

#Preview("Dictation bar — every state", traits: .sizeThatFitsLayout) {
    DictationBarGallery()
}

#Preview("Dictation bar — every state, dark", traits: .sizeThatFitsLayout) {
    DictationBarGallery(dark: true)
}

#Preview("Dictation bar — every height", traits: .sizeThatFitsLayout) {
    VStack(alignment: .leading, spacing: 10) {
        ForEach(KeyboardHeightPreference.allCases) { preference in
            Text(preference.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            DictationBarPreview(
                context: DictationContext(
                    state: .idle,
                    candidates: KeyboardPreviewEnvironment.candidates
                ),
                preference: preference
            )
        }
    }
    .padding()
}
#endif
