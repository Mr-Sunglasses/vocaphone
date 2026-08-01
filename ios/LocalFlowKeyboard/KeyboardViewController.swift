import UIKit

final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    private let store = SharedStore.shared
    private var activeSessionID: UUID?
    private var pollingTimer: Timer?
    private var appLaunchFallbackTask: Task<Void, Never>?
    private var lastInsertedText: String?
    private var isShifted = true
    private var isPerformingInsertion = false
    private var letterButtons: [UIButton] = []
    private var shiftButton: UIButton?

    private var currentDocumentID: String? {
        // On iOS 26 the proxy can temporarily return nil during viewDidLoad even
        // though UITextDocumentProxy declares this property as non-optional.
        // Read it through Objective-C so the extension can wait instead of
        // trapping in Swift's unconditional UUID bridge.
        guard let proxy = textDocumentProxy as? NSObject else { return nil }
        let selector = NSSelectorFromString("documentIdentifier")
        guard proxy.responds(to: selector),
              let identifier = proxy.value(forKey: "documentIdentifier") as? UUID
        else { return nil }
        return identifier.uuidString
    }

    private let statusLabel = UILabel()
    private let meterView = VoiceMeterView()
    private let primaryButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let languageLabel = UILabel()
    private let styleButton = UIButton(type: .system)
    private let dictationCard = UIView()
    private let recordingDot = UIView()
    private let toolbarStack = UIStackView()

    var enableInputClicksWhenVisible: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        inputView?.allowsSelfSizing = true
        configureUI()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (controller: KeyboardViewController, _) in
            controller.applyTheme()
        }
        render(nil)
        beginPolling()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        beginPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollingTimer?.invalidate()
        appLaunchFallbackTask?.cancel()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        updateAutomaticShift()
    }

    @objc private func primaryTapped() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        guard hasFullAccess else {
            statusLabel.text = "Enable Full Access for Local Flow in Keyboard Settings."
            return
        }
        guard let id = activeSessionID,
              var record = try? store.load(id)
        else {
            startSession()
            return
        }
        switch record.state {
        case .recording:
            transition(&record, to: .finalizing)
        case .readyToInsert:
            insert(&record)
        case .launchingApp, .awaitingReturn:
            openContainingApp(for: record)
        default:
            startSession()
        }
    }

    @objc private func cancelTapped() {
        guard let id = activeSessionID, var record = try? store.load(id) else { return }
        transition(&record, to: .canceled)
    }

    @objc private func retryTapped() {
        guard let id = activeSessionID,
              var record = try? store.load(id),
              record.canRetry
        else { return }
        record.error = nil
        transition(&record, to: .uploading)
        guard let url = URL(
            string: "\(AppConfiguration.urlScheme)://retry?session=\(record.sessionID.uuidString)"
        ) else { return }
        openURLFromKeyboard(url) { [weak self] opened in
            DispatchQueue.main.async {
                if !opened {
                    self?.statusLabel.text = "Open Local Flow to retry the preserved recording."
                }
            }
        }
    }

    @objc private func undoTapped() {
        guard let inserted = lastInsertedText,
              textDocumentProxy.documentContextBeforeInput?.hasSuffix(inserted) == true
        else {
            statusLabel.text = "Cursor moved; undo is unavailable."
            return
        }
        inserted.forEach { _ in textDocumentProxy.deleteBackward() }
        lastInsertedText = nil
        undoButton.isEnabled = false
        undoButton.isHidden = true
        statusLabel.text = "Last insertion removed."
    }

    @objc private func globeTapped() {
        advanceToNextInputMode()
    }

    @objc private func letterTapped(_ sender: UIButton) {
        guard let letter = sender.accessibilityIdentifier else { return }
        playKeyClick()
        textDocumentProxy.insertText(isShifted ? letter.uppercased() : letter)
        setShifted(false)
    }

    @objc private func shiftTapped() {
        playKeyClick()
        setShifted(!isShifted)
    }

    @objc private func deleteTapped() {
        playKeyClick()
        textDocumentProxy.deleteBackward()
        updateAutomaticShift()
    }

    @objc private func spaceTapped() {
        playKeyClick()
        textDocumentProxy.insertText(" ")
    }

    @objc private func commaTapped() {
        playKeyClick()
        textDocumentProxy.insertText(",")
        setShifted(false)
    }

    @objc private func periodTapped() {
        playKeyClick()
        textDocumentProxy.insertText(".")
        setShifted(true)
    }

    @objc private func returnTapped() {
        playKeyClick()
        textDocumentProxy.insertText("\n")
        setShifted(true)
    }

    @objc private func keyTouchDown(_ sender: UIButton) {
        let changes = {
            sender.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
            sender.alpha = 0.78
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        UIView.animate(
            withDuration: 0.055,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: changes
        )
    }

    @objc private func keyTouchEnded(_ sender: UIButton) {
        let changes = {
            sender.transform = .identity
            sender.alpha = 1
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        UIView.animate(
            withDuration: 0.1,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: changes
        )
    }

    private func startSession() {
        guard hasFullAccess else {
            statusLabel.text = "Enable Full Access for Local Flow in Keyboard Settings."
            return
        }
        var record = SessionRecord(
            state: .idle,
            sourceDocumentID: currentDocumentID,
            language: "auto",
            style: KeyboardPreferences.writingStyle.rawValue
        )
        do {
            try record.transition(to: .launchingApp)
            try store.save(record)
            activeSessionID = record.sessionID
            render(record)
            if let availability = try? store.loadQuickDictationAvailability(),
               availability.isReady()
            {
                statusLabel.text = "Starting with Quick Dictation…"
                scheduleContainingAppFallback(for: record)
            } else {
                openContainingApp(for: record)
            }
        } catch {
            statusLabel.text = "Could not create a shared session."
        }
    }

    private func insert(_ record: inout SessionRecord) {
        guard !isPerformingInsertion else { return }
        guard let transcript = record.transcript, !transcript.isEmpty else { return }
        isPerformingInsertion = true
        defer { isPerformingInsertion = false }
        let prepared = TextInsertion.preparedTranscript(
            transcript,
            before: textDocumentProxy.documentContextBeforeInput,
            after: textDocumentProxy.documentContextAfterInput
        )
        do {
            try record.transition(to: .inserting)
            try store.save(record)
            textDocumentProxy.insertText(prepared)
            lastInsertedText = prepared
            try record.transition(to: .inserted)
            try store.save(record)
            try record.transition(to: .completed)
            try store.save(record)
            activeSessionID = nil
            render(record)
        } catch {
            statusLabel.text = "Insertion was interrupted; text will not be inserted twice."
        }
    }

    private func openContainingApp(for record: SessionRecord) {
        appLaunchFallbackTask?.cancel()
        appLaunchFallbackTask = nil
        guard let url = URL(
            string: "\(AppConfiguration.urlScheme)://dictate?session=\(record.sessionID.uuidString)"
        ) else { return }
        openURLFromKeyboard(url) { [weak self] opened in
            DispatchQueue.main.async {
                guard let self else { return }
                if opened {
                    self.statusLabel.text = "Opening Local Flow…"
                    return
                }
                if var waiting = try? self.store.load(record.sessionID),
                   waiting.state == .launchingApp
                {
                    self.transition(&waiting, to: .awaitingReturn)
                }
                self.statusLabel.text =
                    "Open Local Flow manually; the recording request is waiting."
                self.setPrimaryButton(
                    title: "Try again",
                    symbol: "arrow.up.forward.app.fill",
                    color: .systemIndigo,
                    enabled: true
                )
            }
        }
    }

    private func scheduleContainingAppFallback(for record: SessionRecord) {
        appLaunchFallbackTask?.cancel()
        appLaunchFallbackTask = Task { [weak self] in
            let milliseconds = Int(
                AppConfiguration.quickDictationLaunchFallbackSeconds * 1_000
            )
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled,
                  let self,
                  let current = try? self.store.load(record.sessionID),
                  [.launchingApp, .awaitingReturn].contains(current.state)
            else { return }
            self.openContainingApp(for: current)
        }
    }

    private func openURLFromKeyboard(
        _ url: URL,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        // Custom keyboards don't support opening their containing app through
        // NSExtensionContext on current iOS releases. The responder chain still
        // carries the user-initiated URL request to the owning app or scene.
        if LFOpenURLFromResponderChain(self, url) {
            completion(true)
            return
        }
        guard let extensionContext else {
            completion(false)
            return
        }
        extensionContext.open(url, completionHandler: completion)
    }

    private func transition(_ record: inout SessionRecord, to state: SessionState) {
        do {
            try record.transition(to: state)
            try store.save(record)
            render(record)
        } catch {
            statusLabel.text = "The session changed. Please try again."
        }
    }

    private func beginPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        if let id = activeSessionID, let record = try? store.load(id) {
            if ![.launchingApp, .awaitingReturn].contains(record.state) {
                appLaunchFallbackTask?.cancel()
                appLaunchFallbackTask = nil
            }
            if record.state == .readyToInsert,
               KeyboardPreferences.autoInsertTranscripts
            {
                var mutableRecord = record
                insert(&mutableRecord)
                return
            }
            render(record)
            return
        }
        guard let recent = try? store.recent(limit: 1).first,
              !recent.state.isTerminal,
              recent.sourceDocumentID != "in-app-test"
        else {
            render(nil)
            return
        }
        activeSessionID = recent.sessionID
        if recent.state == .readyToInsert,
           KeyboardPreferences.autoInsertTranscripts
        {
            var mutableRecord = recent
            insert(&mutableRecord)
            return
        }
        render(recent)
    }

    private func render(_ record: SessionRecord?) {
        let selectedStyle = record.flatMap { WritingStyle(rawValue: $0.style) }
            ?? KeyboardPreferences.writingStyle
        guard hasFullAccess else {
            meterView.level = 0
            meterView.isActive = false
            languageLabel.text = "Full Access required"
            configureStyleButton(selected: selectedStyle, enabled: false)
            retryButton.isHidden = true
            cancelButton.isHidden = true
            undoButton.isEnabled = false
            undoButton.isHidden = true
            statusLabel.text = "Keyboard access needed"
            recordingDot.backgroundColor = .systemGray
            updateRecordingPulse(active: false)
            setPrimaryButton(
                title: "Locked",
                symbol: "lock.fill",
                color: .systemGray,
                enabled: false
            )
            return
        }

        let state = record?.state ?? .idle
        meterView.level = record?.meterLevel ?? 0
        meterView.isActive = state == .recording
        configureStyleButton(
            selected: selectedStyle,
            enabled: record == nil || state.isTerminal
        )
        retryButton.isHidden = record?.canRetry != true
        cancelButton.isHidden = ![
            .launchingApp, .awaitingReturn, .recording, .finalizing, .uploading,
        ].contains(state)
        undoButton.isEnabled = lastInsertedText != nil
        undoButton.isHidden = lastInsertedText == nil || (record != nil && !state.isTerminal)
        updateRecordingPulse(active: state == .recording)

        switch state {
        case .idle, .completed, .canceled, .expired:
            statusLabel.text = state == .completed ? "Text inserted" : "Ready"
            languageLabel.text = state == .completed
                ? "Undo is available below"
                : "Auto language · private model"
            recordingDot.backgroundColor = state == .completed ? .systemGreen : .systemBlue
            meterView.activeColor = state == .completed ? .systemGreen : .systemBlue
            setPrimaryButton(
                title: "Dictate",
                symbol: "mic.fill",
                color: .systemBlue,
                enabled: true
            )
        case .launchingApp, .awaitingReturn:
            statusLabel.text = "Opening Local Flow…"
            languageLabel.text = "Get ready to speak"
            recordingDot.backgroundColor = .systemIndigo
            meterView.activeColor = .systemIndigo
            setPrimaryButton(
                title: "Open app",
                symbol: "arrow.up.forward.app.fill",
                color: .systemIndigo,
                enabled: true
            )
        case .recording:
            statusLabel.text = "Listening…"
            languageLabel.text = "Tap Finish when you’re done"
            recordingDot.backgroundColor = .systemRed
            meterView.activeColor = .systemRed
            setPrimaryButton(
                title: "Finish",
                symbol: "stop.fill",
                color: .systemRed,
                enabled: true
            )
        case .finalizing, .uploading, .transcribing:
            statusLabel.text = state == .transcribing ? "Transcribing on Mac…" : "Sending to Mac…"
            languageLabel.text = state == .transcribing
                ? "Using your private local model"
                : "Your recording stays private"
            recordingDot.backgroundColor = .systemOrange
            meterView.activeColor = .systemOrange
            setPrimaryButton(
                title: "Working…",
                symbol: "waveform",
                color: .systemOrange,
                enabled: false
            )
        case .readyToInsert:
            statusLabel.text = "Transcript ready"
            languageLabel.text = KeyboardPreferences.autoInsertTranscripts
                ? "Inserting automatically…"
                : "Tap Insert to place the text"
            recordingDot.backgroundColor = .systemGreen
            meterView.activeColor = .systemGreen
            setPrimaryButton(
                title: "Insert",
                symbol: "text.badge.plus",
                color: .systemGreen,
                enabled: true
            )
        case .serverUnavailable, .uploadFailedRecoverable, .transcriptionFailedRecoverable:
            statusLabel.text = state == .serverUnavailable
                ? "Mac unavailable"
                : "Transcription paused"
            languageLabel.text = "Recording preserved · Retry when ready"
            recordingDot.backgroundColor = .systemOrange
            meterView.activeColor = .systemOrange
            setPrimaryButton(
                title: "New",
                symbol: "mic.fill",
                color: .systemBlue,
                enabled: true
            )
        case .permissionDenied:
            statusLabel.text = "Microphone access needed"
            languageLabel.text = "Allow access in Local Flow Settings"
            recordingDot.backgroundColor = .systemRed
            meterView.activeColor = .systemRed
            setPrimaryButton(
                title: "Open app",
                symbol: "gear",
                color: .systemRed,
                enabled: true
            )
        case .targetContextChanged:
            statusLabel.text = "Original field changed"
            languageLabel.text = "Return to the original field to insert"
            recordingDot.backgroundColor = .systemOrange
            meterView.activeColor = .systemOrange
            setPrimaryButton(
                title: "Dictate",
                symbol: "mic.fill",
                color: .systemBlue,
                enabled: true
            )
        case .inserting, .inserted:
            statusLabel.text = "Finishing insertion…"
            languageLabel.text = "Placing the transcript at the cursor"
            recordingDot.backgroundColor = .systemGreen
            meterView.activeColor = .systemGreen
            setPrimaryButton(
                title: "Inserting…",
                symbol: "text.badge.checkmark",
                color: .systemGreen,
                enabled: false
            )
        case .transcriptionFailedPermanent:
            statusLabel.text = "Transcription failed"
            languageLabel.text = record?.error?.message ?? "Please make a new recording"
            recordingDot.backgroundColor = .systemRed
            meterView.activeColor = .systemRed
            setPrimaryButton(
                title: "Try again",
                symbol: "arrow.clockwise",
                color: .systemRed,
                enabled: true
            )
        }
    }

    private func configureUI() {
        statusLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        statusLabel.textAlignment = .left
        statusLabel.numberOfLines = 1
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.78
        statusLabel.lineBreakMode = .byTruncatingTail
        languageLabel.font = .systemFont(ofSize: 12, weight: .regular)
        languageLabel.textColor = .secondaryLabel
        languageLabel.textAlignment = .left
        languageLabel.adjustsFontSizeToFitWidth = true
        languageLabel.minimumScaleFactor = 0.82

        styleButton.showsMenuAsPrimaryAction = true
        styleButton.accessibilityLabel = "Writing style"

        recordingDot.layer.cornerRadius = 5
        recordingDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recordingDot.widthAnchor.constraint(equalToConstant: 10),
            recordingDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        meterView.translatesAutoresizingMaskIntoConstraints = false
        meterView.heightAnchor.constraint(equalToConstant: 9).isActive = true

        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        primaryButton.accessibilityLabel = "Start or finish private dictation"
        configureUtilityButton(cancelButton, title: "Cancel", symbol: "xmark")
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        configureUtilityButton(retryButton, title: "Retry", symbol: "arrow.clockwise")
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        configureUtilityButton(undoButton, title: "Undo insert", symbol: "arrow.uturn.backward")
        undoButton.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)

        let titleRow = UIStackView(arrangedSubviews: [recordingDot, statusLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8
        languageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusStack = UIStackView(arrangedSubviews: [titleRow, languageLabel, meterView])
        statusStack.axis = .vertical
        statusStack.spacing = 4
        let cardRow = UIStackView(arrangedSubviews: [statusStack, primaryButton])
        cardRow.axis = .horizontal
        cardRow.alignment = .center
        cardRow.spacing = 10
        cardRow.translatesAutoresizingMaskIntoConstraints = false

        dictationCard.layer.cornerRadius = 18
        dictationCard.layer.cornerCurve = .continuous
        dictationCard.layer.shadowColor = UIColor.black.cgColor
        dictationCard.layer.shadowOpacity = 0.08
        dictationCard.layer.shadowRadius = 3
        dictationCard.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        dictationCard.layer.borderWidth = 0.5
        dictationCard.addSubview(cardRow)
        NSLayoutConstraint.activate([
            cardRow.leadingAnchor.constraint(equalTo: dictationCard.leadingAnchor, constant: 14),
            cardRow.trailingAnchor.constraint(equalTo: dictationCard.trailingAnchor, constant: -11),
            cardRow.topAnchor.constraint(equalTo: dictationCard.topAnchor, constant: 10),
            cardRow.bottomAnchor.constraint(equalTo: dictationCard.bottomAnchor, constant: -10),
            dictationCard.heightAnchor.constraint(equalToConstant: 76),
            primaryButton.widthAnchor.constraint(equalToConstant: 112),
            primaryButton.heightAnchor.constraint(equalToConstant: 48),
        ])

        let toolbarSpacer = UIView()
        toolbarSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbarStack.addArrangedSubview(styleButton)
        toolbarStack.addArrangedSubview(toolbarSpacer)
        toolbarStack.addArrangedSubview(cancelButton)
        toolbarStack.addArrangedSubview(retryButton)
        toolbarStack.addArrangedSubview(undoButton)
        toolbarStack.axis = .horizontal
        toolbarStack.alignment = .center
        toolbarStack.spacing = 6
        styleButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.isHidden = true
        retryButton.isHidden = true
        undoButton.isHidden = true

        let typingStack = makeTypingStack()
        let stack = UIStackView(arrangedSubviews: [
            dictationCard, toolbarStack, typingStack,
        ])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let preferredHeight = view.heightAnchor.constraint(equalToConstant: 326)
        preferredHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -6),
            toolbarStack.heightAnchor.constraint(equalToConstant: 34),
            preferredHeight,
        ])
        applyTheme()
        updateAutomaticShift()
    }

    private func makeTypingStack() -> UIStackView {
        let firstRow = makeKeyRow("qwertyuiop".map { makeLetterButton(String($0)) })
        let secondRow = makeIndentedKeyRow(
            "asdfghjkl".map { makeLetterButton(String($0)) }
        )

        let shift = makeKeyButton(
            title: nil,
            symbol: "shift",
            accessibilityLabel: "Shift",
            action: #selector(shiftTapped),
            style: .function
        )
        shiftButton = shift
        let thirdRowLetters = "zxcvbnm".map { makeLetterButton(String($0)) }
        let delete = makeKeyButton(
            title: nil,
            symbol: "delete.left",
            accessibilityLabel: "Delete",
            action: #selector(deleteTapped),
            style: .function
        )
        let thirdRow = makeKeyRow([shift] + thirdRowLetters + [delete], distribution: .fill)
        NSLayoutConstraint.activate([
            shift.widthAnchor.constraint(equalToConstant: 46),
            delete.widthAnchor.constraint(equalToConstant: 46),
        ])
        for button in thirdRowLetters.dropFirst() {
            button.widthAnchor.constraint(equalTo: thirdRowLetters[0].widthAnchor).isActive = true
        }

        var globeConfiguration = UIButton.Configuration.filled()
        globeConfiguration.image = UIImage(systemName: "globe")
        globeConfiguration.cornerStyle = .medium
        globeConfiguration.baseBackgroundColor = KeyStyle.function.backgroundColor
        globeConfiguration.baseForegroundColor = KeyStyle.function.foregroundColor
        globeConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 17,
            weight: .medium
        )
        globeButton.configuration = globeConfiguration
        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)
        addKeyTouchFeedback(to: globeButton)
        globeButton.layer.shadowColor = UIColor.black.cgColor
        globeButton.layer.shadowOpacity = 0.16
        globeButton.layer.shadowRadius = 0.75
        globeButton.layer.shadowOffset = CGSize(width: 0, height: 1.25)
        globeButton.heightAnchor.constraint(equalToConstant: 43).isActive = true
        let comma = makeKeyButton(
            title: ",",
            accessibilityLabel: "Comma",
            action: #selector(commaTapped)
        )
        let space = makeKeyButton(
            title: "space",
            accessibilityLabel: "Space",
            action: #selector(spaceTapped)
        )
        let period = makeKeyButton(
            title: ".",
            accessibilityLabel: "Period",
            action: #selector(periodTapped)
        )
        let returnKey = makeKeyButton(
            title: "return",
            accessibilityLabel: "Return",
            action: #selector(returnTapped),
            style: .accent
        )
        let bottomRow = UIStackView(
            arrangedSubviews: [globeButton, comma, space, period, returnKey]
        )
        bottomRow.axis = .horizontal
        bottomRow.spacing = 6
        bottomRow.distribution = .fill
        NSLayoutConstraint.activate([
            globeButton.widthAnchor.constraint(equalToConstant: 46),
            comma.widthAnchor.constraint(equalToConstant: 40),
            period.widthAnchor.constraint(equalToConstant: 40),
            returnKey.widthAnchor.constraint(equalToConstant: 76),
        ])

        let stack = UIStackView(arrangedSubviews: [firstRow, secondRow, thirdRow, bottomRow])
        stack.axis = .vertical
        stack.spacing = 6
        stack.distribution = .fillEqually
        return stack
    }

    private func makeLetterButton(_ letter: String) -> UIButton {
        let button = makeKeyButton(
            title: letter,
            accessibilityLabel: letter.uppercased(),
            action: #selector(letterTapped(_:))
        )
        button.accessibilityIdentifier = letter
        letterButtons.append(button)
        return button
    }

    private func makeKeyButton(
        title: String?,
        symbol: String? = nil,
        accessibilityLabel: String,
        action: Selector,
        style: KeyStyle = .standard
    ) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = style.backgroundColor
        configuration.baseForegroundColor = style.foregroundColor
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 17,
            weight: .medium
        )
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: 4,
            bottom: 0,
            trailing: 4
        )
        let isCharacterKey = title?.count == 1 && title?.first?.isLetter == true
        let font = isCharacterKey
            ? UIFont.systemFont(ofSize: 20, weight: .regular)
            : UIFont.systemFont(ofSize: 16, weight: .medium)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
        button.configuration = configuration
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        addKeyTouchFeedback(to: button)
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.16
        button.layer.shadowRadius = 0.75
        button.layer.shadowOffset = CGSize(width: 0, height: 1.25)
        button.heightAnchor.constraint(equalToConstant: 43).isActive = true
        return button
    }

    private func makeKeyRow(
        _ buttons: [UIButton],
        distribution: UIStackView.Distribution = .fillEqually
    ) -> UIStackView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = distribution
        return row
    }

    private func makeIndentedKeyRow(_ buttons: [UIButton]) -> UIView {
        let container = UIView()
        let row = makeKeyRow(buttons)
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func configureUtilityButton(_ button: UIButton, title: String, symbol: String) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 5
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 5,
            leading: 10,
            bottom: 5,
            trailing: 10
        )
        configuration.baseBackgroundColor = KeyboardPalette.toolbarControl
        configuration.baseForegroundColor = .label
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .semibold)
            return outgoing
        }
        button.configuration = configuration
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    private func configureStyleButton(selected: WritingStyle, enabled: Bool) {
        let actions = WritingStyle.allCases.map { style in
            UIAction(
                title: style.displayName,
                image: UIImage(systemName: style.symbolName),
                state: style == selected ? .on : .off
            ) { [weak self] _ in
                KeyboardPreferences.writingStyle = style
                self?.refresh()
            }
        }
        styleButton.menu = UIMenu(title: "Writing style", children: actions)

        var configuration = UIButton.Configuration.filled()
        configuration.title = selected.displayName
        configuration.image = UIImage(systemName: selected.symbolName)
        configuration.imagePadding = 5
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 5,
            leading: 10,
            bottom: 5,
            trailing: 10
        )
        configuration.baseBackgroundColor = KeyboardPalette.toolbarControl
        configuration.baseForegroundColor = .systemBlue
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .semibold)
            return outgoing
        }
        styleButton.configuration = configuration
        styleButton.isEnabled = enabled
        styleButton.accessibilityValue = selected.displayName
    }

    private func setPrimaryButton(
        title: String,
        symbol: String,
        color: UIColor,
        enabled: Bool
    ) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 7
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = color
        configuration.baseForegroundColor = .white
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 15, weight: .semibold)
            return outgoing
        }
        primaryButton.configuration = configuration
        primaryButton.isEnabled = enabled
        primaryButton.accessibilityLabel = title
        primaryButton.accessibilityValue = statusLabel.text
        primaryButton.accessibilityHint = switch title {
        case "Dictate": "Opens Local Flow and starts private dictation."
        case "Finish": "Stops recording and starts transcription."
        case "Insert": "Inserts the transcript at the cursor."
        case "Open app": "Opens Local Flow to continue."
        default: nil
        }
    }

    private func addKeyTouchFeedback(to button: UIButton) {
        button.addTarget(self, action: #selector(keyTouchDown(_:)), for: .touchDown)
        button.addTarget(
            self,
            action: #selector(keyTouchEnded(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
    }

    private func applyTheme() {
        view.backgroundColor = KeyboardPalette.background
        inputView?.backgroundColor = KeyboardPalette.background
        dictationCard.backgroundColor = KeyboardPalette.card
        dictationCard.layer.borderColor = KeyboardPalette.cardBorder.resolvedColor(
            with: traitCollection
        ).cgColor
    }

    private func updateRecordingPulse(active: Bool) {
        let animationKey = "localflow.recordingPulse"
        guard active else {
            recordingDot.layer.removeAnimation(forKey: animationKey)
            recordingDot.layer.opacity = 1
            return
        }
        guard recordingDot.layer.animation(forKey: animationKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.32
        pulse.duration = 0.78
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        recordingDot.layer.add(pulse, forKey: animationKey)
    }

    private func playKeyClick() {
        UIDevice.current.playInputClick()
    }

    private func setShifted(_ shifted: Bool) {
        isShifted = shifted
        for button in letterButtons {
            guard let letter = button.accessibilityIdentifier else { continue }
            button.configuration?.title = shifted ? letter.uppercased() : letter
        }
        if let shiftButton, var configuration = shiftButton.configuration {
            configuration.image = UIImage(systemName: shifted ? "shift.fill" : "shift")
            configuration.baseBackgroundColor = shifted
                ? KeyboardPalette.shiftKeyActive
                : KeyStyle.function.backgroundColor
            configuration.baseForegroundColor = shifted ? .white : .label
            shiftButton.configuration = configuration
            shiftButton.accessibilityValue = shifted ? "On" : "Off"
        }
    }

    private func updateAutomaticShift() {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldShift = trimmed.isEmpty
            || before.hasSuffix("\n")
            || before.hasSuffix(". ")
            || before.hasSuffix("! ")
            || before.hasSuffix("? ")
        setShifted(shouldShift)
    }

    private enum KeyStyle {
        case standard
        case function
        case accent

        var backgroundColor: UIColor {
            switch self {
            case .standard: KeyboardPalette.standardKey
            case .function: KeyboardPalette.functionKey
            case .accent: .systemBlue
            }
        }

        var foregroundColor: UIColor {
            self == .accent ? .white : .label
        }
    }

    private enum KeyboardPalette {
        static let background = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.075, green: 0.082, blue: 0.095, alpha: 1)
                : UIColor(red: 0.82, green: 0.835, blue: 0.86, alpha: 1)
        }

        static let card = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.145, green: 0.155, blue: 0.18, alpha: 1)
                : UIColor(red: 0.97, green: 0.975, blue: 0.985, alpha: 1)
        }

        static let cardBorder = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.08)
                : UIColor.black.withAlphaComponent(0.07)
        }

        static let standardKey = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.275, green: 0.29, blue: 0.325, alpha: 1)
                : .white
        }

        static let functionKey = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.17, green: 0.18, blue: 0.205, alpha: 1)
                : UIColor(red: 0.66, green: 0.685, blue: 0.72, alpha: 1)
        }

        static let toolbarControl = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.2, green: 0.215, blue: 0.245, alpha: 1)
                : UIColor(white: 0.95, alpha: 1)
        }

        static let shiftKeyActive = UIColor.systemBlue
    }
}

private final class VoiceMeterView: UIView {
    var level: Float = 0 {
        didSet {
            updateAccessibilityValue()
            setNeedsDisplay()
        }
    }

    var isActive = false {
        didSet {
            updateAccessibilityValue()
            setNeedsDisplay()
        }
    }

    var activeColor: UIColor = .systemBlue {
        didSet { setNeedsDisplay() }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 120, height: 9)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityLabel = "Voice level"
        accessibilityTraits = [.updatesFrequently]
        updateAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        let pattern: [CGFloat] = [
            0.28, 0.46, 0.72, 0.42, 0.86, 0.58, 1, 0.7, 0.48,
            0.9, 0.62, 0.38, 0.76, 0.52, 0.88, 0.44, 0.66, 0.3,
        ]
        let gap: CGFloat = 2.2
        let totalGaps = gap * CGFloat(pattern.count - 1)
        let barWidth = max(1.5, (bounds.width - totalGaps) / CGFloat(pattern.count))
        let normalizedLevel = min(max(CGFloat(level), 0), 1)
        let energy = isActive ? max(0.16, normalizedLevel) : 0.09
        let color = activeColor.withAlphaComponent(isActive ? 0.88 : 0.22)
        color.setFill()

        for (index, value) in pattern.enumerated() {
            let scaledEnergy = min(1, energy * (0.55 + value * 0.85))
            let height = max(2, bounds.height * scaledEnergy)
            let x = CGFloat(index) * (barWidth + gap)
            let bar = CGRect(
                x: x,
                y: bounds.midY - height / 2,
                width: barWidth,
                height: height
            )
            UIBezierPath(roundedRect: bar, cornerRadius: barWidth / 2).fill()
        }
    }

    private func updateAccessibilityValue() {
        let normalizedLevel = min(max(level, 0), 1)
        accessibilityValue = isActive
            ? "\(Int(normalizedLevel * 100)) percent"
            : "Not recording"
    }
}
