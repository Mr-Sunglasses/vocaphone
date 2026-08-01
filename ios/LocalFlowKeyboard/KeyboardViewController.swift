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
    private let meterView = UIProgressView(progressViewStyle: .default)
    private let primaryButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let languageLabel = UILabel()
    private let styleButton = UIButton(type: .system)
    private let dictationCard = UIView()
    private let recordingDot = UIView()

    var enableInputClicksWhenVisible: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        inputView?.allowsSelfSizing = true
        configureUI()
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
            meterView.progress = 0
            languageLabel.text = "FULL ACCESS REQUIRED"
            configureStyleButton(selected: selectedStyle, enabled: false)
            retryButton.isHidden = true
            cancelButton.isHidden = true
            undoButton.isEnabled = false
            statusLabel.text = "Enable Full Access for Local Flow in Keyboard Settings."
            recordingDot.backgroundColor = .systemGray
            setPrimaryButton(
                title: "Access needed",
                symbol: "lock.fill",
                color: .systemGray,
                enabled: false
            )
            return
        }

        let state = record?.state ?? .idle
        meterView.progress = record?.meterLevel ?? 0
        languageLabel.text = record?.language.uppercased() ?? "AUTO"
        configureStyleButton(
            selected: selectedStyle,
            enabled: record == nil || state.isTerminal
        )
        retryButton.isHidden = record?.canRetry != true
        cancelButton.isHidden = ![.launchingApp, .recording, .uploading].contains(state)
        undoButton.isEnabled = lastInsertedText != nil

        switch state {
        case .idle, .completed, .canceled, .expired:
            statusLabel.text = state == .completed ? "Transcript inserted" : "Ready to dictate"
            recordingDot.backgroundColor = state == .completed ? .systemGreen : .systemBlue
            setPrimaryButton(
                title: "Dictate",
                symbol: "mic.fill",
                color: .systemBlue,
                enabled: true
            )
        case .launchingApp, .awaitingReturn:
            statusLabel.text = "Opening Local Flow…"
            recordingDot.backgroundColor = .systemIndigo
            setPrimaryButton(
                title: "Open app",
                symbol: "arrow.up.forward.app.fill",
                color: .systemIndigo,
                enabled: true
            )
        case .recording:
            statusLabel.text = "Listening in Local Flow"
            recordingDot.backgroundColor = .systemRed
            setPrimaryButton(
                title: "Finish",
                symbol: "stop.fill",
                color: .systemRed,
                enabled: true
            )
        case .finalizing, .uploading, .transcribing:
            statusLabel.text = state == .transcribing ? "Transcribing on Mac…" : "Sending to Mac…"
            recordingDot.backgroundColor = .systemOrange
            setPrimaryButton(
                title: "Working…",
                symbol: "waveform",
                color: .systemOrange,
                enabled: false
            )
        case .readyToInsert:
            statusLabel.text = "Transcript ready"
            recordingDot.backgroundColor = .systemGreen
            setPrimaryButton(
                title: "Insert",
                symbol: "text.badge.plus",
                color: .systemGreen,
                enabled: true
            )
        case .serverUnavailable, .uploadFailedRecoverable, .transcriptionFailedRecoverable:
            statusLabel.text = record?.error?.message ?? "Recording preserved; retry when ready."
            recordingDot.backgroundColor = .systemOrange
            setPrimaryButton(
                title: "New recording",
                symbol: "mic.fill",
                color: .systemBlue,
                enabled: true
            )
        case .permissionDenied:
            statusLabel.text = "Allow microphone access in Local Flow Settings."
            recordingDot.backgroundColor = .systemRed
            setPrimaryButton(
                title: "Open app",
                symbol: "gear",
                color: .systemRed,
                enabled: true
            )
        case .targetContextChanged:
            statusLabel.text = "Return to the original field to insert."
            recordingDot.backgroundColor = .systemOrange
            setPrimaryButton(
                title: "Dictate",
                symbol: "mic.fill",
                color: .systemBlue,
                enabled: true
            )
        case .inserting, .inserted:
            statusLabel.text = "Finishing insertion…"
            recordingDot.backgroundColor = .systemGreen
            setPrimaryButton(
                title: "Inserting…",
                symbol: "text.badge.checkmark",
                color: .systemGreen,
                enabled: false
            )
        case .transcriptionFailedPermanent:
            statusLabel.text = record?.error?.message ?? "This recording could not be transcribed."
            recordingDot.backgroundColor = .systemRed
            setPrimaryButton(
                title: "Try again",
                symbol: "arrow.clockwise",
                color: .systemRed,
                enabled: true
            )
        }
    }

    private func configureUI() {
        view.backgroundColor = .systemGray5
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.textAlignment = .left
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.82
        languageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        languageLabel.textColor = .secondaryLabel
        languageLabel.textAlignment = .left

        styleButton.showsMenuAsPrimaryAction = true
        styleButton.accessibilityLabel = "Writing style"

        recordingDot.layer.cornerRadius = 5
        recordingDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recordingDot.widthAnchor.constraint(equalToConstant: 10),
            recordingDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        meterView.trackTintColor = .systemGray5
        meterView.progressTintColor = .systemRed

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
        let metadataRow = UIStackView(arrangedSubviews: [languageLabel, styleButton])
        metadataRow.axis = .horizontal
        metadataRow.alignment = .center
        metadataRow.spacing = 6
        languageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        styleButton.setContentHuggingPriority(.required, for: .horizontal)
        let statusStack = UIStackView(arrangedSubviews: [titleRow, metadataRow, meterView])
        statusStack.axis = .vertical
        statusStack.spacing = 5
        let cardRow = UIStackView(arrangedSubviews: [statusStack, primaryButton])
        cardRow.axis = .horizontal
        cardRow.alignment = .center
        cardRow.spacing = 12
        cardRow.translatesAutoresizingMaskIntoConstraints = false

        dictationCard.backgroundColor = .systemBackground
        dictationCard.layer.cornerRadius = 18
        dictationCard.layer.cornerCurve = .continuous
        dictationCard.layer.shadowColor = UIColor.black.cgColor
        dictationCard.layer.shadowOpacity = 0.10
        dictationCard.layer.shadowRadius = 2
        dictationCard.layer.shadowOffset = CGSize(width: 0, height: 1)
        dictationCard.addSubview(cardRow)
        NSLayoutConstraint.activate([
            cardRow.leadingAnchor.constraint(equalTo: dictationCard.leadingAnchor, constant: 14),
            cardRow.trailingAnchor.constraint(equalTo: dictationCard.trailingAnchor, constant: -10),
            cardRow.topAnchor.constraint(equalTo: dictationCard.topAnchor, constant: 9),
            cardRow.bottomAnchor.constraint(equalTo: dictationCard.bottomAnchor, constant: -9),
            dictationCard.heightAnchor.constraint(equalToConstant: 70),
            primaryButton.widthAnchor.constraint(equalToConstant: 122),
            primaryButton.heightAnchor.constraint(equalToConstant: 48),
        ])

        let actions = UIStackView(arrangedSubviews: [cancelButton, retryButton, undoButton])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 6
        let typingStack = makeTypingStack()
        let stack = UIStackView(arrangedSubviews: [
            dictationCard, actions, typingStack,
        ])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let preferredHeight = view.heightAnchor.constraint(equalToConstant: 310)
        preferredHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -6),
            actions.heightAnchor.constraint(equalToConstant: 30),
            preferredHeight,
        ])
        updateAutomaticShift()
    }

    private func makeTypingStack() -> UIStackView {
        let firstRow = makeKeyRow("qwertyuiop".map { makeLetterButton(String($0)) })
        let secondRow = makeIndentedKeyRow(
            "asdfghjkl".map { makeLetterButton(String($0)) }
        )

        let shift = makeKeyButton(
            title: "⇧",
            accessibilityLabel: "Shift",
            action: #selector(shiftTapped),
            style: .function
        )
        let thirdRowLetters = "zxcvbnm".map { makeLetterButton(String($0)) }
        let delete = makeKeyButton(
            title: "⌫",
            accessibilityLabel: "Delete",
            action: #selector(deleteTapped),
            style: .function
        )
        let thirdRow = makeKeyRow([shift] + thirdRowLetters + [delete], distribution: .fill)
        NSLayoutConstraint.activate([
            shift.widthAnchor.constraint(equalToConstant: 44),
            delete.widthAnchor.constraint(equalToConstant: 44),
        ])
        for button in thirdRowLetters.dropFirst() {
            button.widthAnchor.constraint(equalTo: thirdRowLetters[0].widthAnchor).isActive = true
        }

        var globeConfiguration = UIButton.Configuration.filled()
        globeConfiguration.image = UIImage(systemName: "globe")
        globeConfiguration.cornerStyle = .medium
        globeConfiguration.baseBackgroundColor = KeyStyle.function.backgroundColor
        globeConfiguration.baseForegroundColor = KeyStyle.function.foregroundColor
        globeButton.configuration = globeConfiguration
        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)
        globeButton.layer.shadowColor = UIColor.black.cgColor
        globeButton.layer.shadowOpacity = 0.14
        globeButton.layer.shadowRadius = 0.5
        globeButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        globeButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
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
        bottomRow.spacing = 5
        bottomRow.distribution = .fill
        NSLayoutConstraint.activate([
            globeButton.widthAnchor.constraint(equalToConstant: 42),
            comma.widthAnchor.constraint(equalToConstant: 38),
            period.widthAnchor.constraint(equalToConstant: 38),
            returnKey.widthAnchor.constraint(equalToConstant: 74),
        ])

        let stack = UIStackView(arrangedSubviews: [firstRow, secondRow, thirdRow, bottomRow])
        stack.axis = .vertical
        stack.spacing = 5
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
        title: String,
        accessibilityLabel: String,
        action: Selector,
        style: KeyStyle = .standard
    ) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = style.backgroundColor
        configuration.baseForegroundColor = style.foregroundColor
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: 4,
            bottom: 0,
            trailing: 4
        )
        button.configuration = configuration
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.14
        button.layer.shadowRadius = 0.5
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return button
    }

    private func makeKeyRow(
        _ buttons: [UIButton],
        distribution: UIStackView.Distribution = .fillEqually
    ) -> UIStackView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.spacing = 5
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
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 5
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        button.configuration = configuration
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

        var configuration = UIButton.Configuration.tinted()
        configuration.title = selected.displayName
        configuration.image = UIImage(systemName: selected.symbolName)
        configuration.imagePadding = 4
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 2,
            leading: 7,
            bottom: 2,
            trailing: 7
        )
        configuration.baseForegroundColor = .systemBlue
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
        primaryButton.configuration = configuration
        primaryButton.isEnabled = enabled
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
            case .standard: .systemBackground
            case .function: .systemGray3
            case .accent: .systemBlue
            }
        }

        var foregroundColor: UIColor {
            self == .accent ? .white : .label
        }
    }
}
