import UIKit

final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    private let store = SharedStore.shared
    private var activeSessionID: UUID?
    private var pollingTimer: Timer?
    private var appLaunchFallbackTask: Task<Void, Never>?
    private var lastInsertedText: String?
    private var isPerformingInsertion = false
    private var renderedStyle: WritingStyle?
    private var renderedStyleEnabled: Bool?
    private var renderedPrimary: (
        title: String, symbol: String, color: UIColor, enabled: Bool
    )?
    private var lastSpaceInsertedAt: Date?
    private var lastDocumentID: String?
    private var hasActiveSession = false
    private var palette = KeyboardPalette(isDark: false)

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
    private let languageLabel = UILabel()
    private let styleButton = UIButton(type: .system)
    private let dictationCard = UIView()
    private let recordingDot = UIView()
    private let toolbarStack = UIStackView()
    private lazy var keyGrid = KeyGridView(
        metrics: KeyboardMetrics.resolved(for: traitCollection),
        palette: palette
    )
    private var keyboardHeightConstraint: NSLayoutConstraint?
    private var cardHeightConstraint: NSLayoutConstraint?
    private var toolbarHeightConstraint: NSLayoutConstraint?
    private var gridHeightConstraint: NSLayoutConstraint?

    var enableInputClicksWhenVisible: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        inputView?.allowsSelfSizing = true
        configureUI()
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitVerticalSizeClass.self,
            UITraitHorizontalSizeClass.self,
        ]) { (controller: KeyboardViewController, _) in
            controller.applyTheme()
            controller.applyLayoutMetrics()
        }
        // Lets the containing app show whether the keyboard is actually
        // installed, which it has no API to determine on its own.
        try? store.saveKeyboardStatus(KeyboardStatus(hasFullAccess: hasFullAccess))
        render(nil)
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A recreated extension instance can inherit a session the previous one
        // started, so scan once on appear and let `render` decide about polling.
        applyDocumentTraits()
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollingTimer?.invalidate()
        pollingTimer = nil
        appLaunchFallbackTask?.cancel()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        // Moving to a different field brings different traits with it, and the
        // plane should reset so a number pad never leaves the user on letters.
        let documentID = currentDocumentID
        if documentID != lastDocumentID {
            lastDocumentID = documentID
            lastSpaceInsertedAt = nil
            applyDocumentTraits()
            keyGrid.plane = Self.initialPlane(
                for: textDocumentProxy.keyboardType ?? .default
            )
        }
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
        case .targetContextChanged:
            // Tapping Insert is an explicit request for the transcript in
            // whatever field the cursor is in now, so the guard is bypassed
            // rather than leaving the transcript unreachable.
            transition(&record, to: .readyToInsert)
            insert(&record, force: true)
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

    // MARK: - Typing

    func keyGrid(_ grid: KeyGridView, didProduce output: KeyboardOutput) {
        switch output {
        case let .text(text):
            textDocumentProxy.insertText(text)
            lastSpaceInsertedAt = nil
            releaseUndoIfDetached()
        case .space:
            insertSpace()
        case .newline:
            textDocumentProxy.insertText("\n")
            lastSpaceInsertedAt = nil
            releaseUndoIfDetached()
        case .deleteBackward:
            textDocumentProxy.deleteBackward()
            lastSpaceInsertedAt = nil
            releaseUndoIfDetached()
        case .deleteWord:
            deleteWordBackward()
            releaseUndoIfDetached()
        case let .nextInputMode(anchor, event):
            // `handleInputModeList` also drives the long-press keyboard picker,
            // which `advanceToNextInputMode` alone cannot offer.
            if let event {
                handleInputModeList(from: anchor, with: event)
            } else {
                advanceToNextInputMode()
            }
        }
    }

    func keyGridDidChangeShift(_ grid: KeyGridView) {}

    private func insertSpace() {
        let proxy = textDocumentProxy
        let before = proxy.documentContextBeforeInput ?? ""
        // A second space closes the sentence instead of doubling the gap, which
        // is the iOS behaviour people type by reflex.
        if let previous = lastSpaceInsertedAt,
           Date().timeIntervalSince(previous) < 1.2,
           before.hasSuffix(" "),
           !before.hasSuffix("  "),
           let preceding = before.dropLast().last,
           preceding.isLetter || preceding.isNumber
        {
            proxy.deleteBackward()
            proxy.insertText(". ")
            lastSpaceInsertedAt = nil
        } else {
            proxy.insertText(" ")
            lastSpaceInsertedAt = Date()
        }
        releaseUndoIfDetached()
    }

    private func deleteWordBackward() {
        let proxy = textDocumentProxy
        guard let before = proxy.documentContextBeforeInput, !before.isEmpty else {
            proxy.deleteBackward()
            return
        }
        var count = 0
        var reachedWord = false
        for character in before.reversed() {
            if character.isWhitespace, reachedWord { break }
            if !character.isWhitespace { reachedWord = true }
            count += 1
            if count >= 40 { break }
        }
        for _ in 0..<max(count, 1) { proxy.deleteBackward() }
    }

    /// Undo only makes sense while the transcript is still the tail of the
    /// document. Typing over it retires the offer rather than leaving a button
    /// that would delete the wrong characters.
    private func releaseUndoIfDetached() {
        guard let inserted = lastInsertedText,
              textDocumentProxy.documentContextBeforeInput?.hasSuffix(inserted) != true
        else { return }
        lastInsertedText = nil
        undoButton.isEnabled = false
        undoButton.isHidden = true
    }

    /// Starting a fresh dictation abandons a transcript the user chose not to
    /// insert. Retiring that record keeps `mostRecent` from re-adopting it once
    /// the new session finishes.
    private func discardParkedSession() {
        guard let id = activeSessionID,
              var parked = try? store.load(id),
              !parked.state.isTerminal
        else { return }
        do {
            try parked.transition(to: .canceled)
            try store.save(parked)
            activeSessionID = nil
        } catch {
            // A session still moving through the pipeline resolves on its own.
        }
    }

    private func startSession() {
        guard hasFullAccess else {
            statusLabel.text = "Enable Full Access for Local Flow in Keyboard Settings."
            return
        }
        discardParkedSession()
        var record = SessionRecord(
            state: .idle,
            sourceDocumentID: currentDocumentID,
            language: "auto",
            style: KeyboardPreferences.writingStyle.rawValue
        )
        // Dictating into Local Flow's own field means there is nowhere to swipe
        // back to; the app needs to know so it does not cover that field with
        // hand-off instructions.
        record.startedInContainingApp = KeyboardPreferences.containingAppIsForeground
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

    /// A transcript belongs to the field it was dictated for. iOS may withhold
    /// the document identifier, so only a confirmed mismatch between two known
    /// identifiers blocks insertion; an unknown identifier must not strand a
    /// transcript the user is waiting for.
    private func documentMatchesSource(of record: SessionRecord) -> Bool {
        guard let source = record.sourceDocumentID,
              let current = currentDocumentID
        else { return true }
        return source == current
    }

    private func insert(_ record: inout SessionRecord, force: Bool = false) {
        guard !isPerformingInsertion else { return }
        guard let transcript = record.transcript, !transcript.isEmpty else { return }
        guard force || documentMatchesSource(of: record) else {
            if record.state == .readyToInsert {
                transition(&record, to: .targetContextChanged)
            }
            return
        }
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

    /// The keyboard is the only writer that opens a session, so an idle keyboard
    /// has nothing to wait for. Polling runs only while a session is in flight,
    /// which keeps ordinary typing free of a four-times-a-second directory scan
    /// inside a memory-constrained extension.
    private func updatePolling(for record: SessionRecord?) {
        let needsUpdates = record.map { !$0.state.isTerminal } ?? false
        guard needsUpdates else {
            pollingTimer?.invalidate()
            pollingTimer = nil
            return
        }
        guard pollingTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Common mode keeps session updates flowing while a touch is being
        // tracked on the key grid.
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
    }

    private func refresh() {
        if let id = activeSessionID, let record = try? store.load(id) {
            if ![.launchingApp, .awaitingReturn].contains(record.state) {
                appLaunchFallbackTask?.cancel()
                appLaunchFallbackTask = nil
            }
            handle(record)
            return
        }
        guard let recent = try? store.mostRecent(),
              !recent.state.isTerminal,
              recent.sourceDocumentID != "in-app-test"
        else {
            render(nil)
            return
        }
        activeSessionID = recent.sessionID
        handle(recent)
    }

    private func handle(_ incoming: SessionRecord) {
        var record = incoming
        // Returning to the field the transcript was dictated for re-arms an
        // insertion that was parked when the cursor moved elsewhere.
        if record.state == .targetContextChanged, documentMatchesSource(of: record) {
            transition(&record, to: .readyToInsert)
        }
        if record.state == .readyToInsert, KeyboardPreferences.autoInsertTranscripts {
            insert(&record)
            return
        }
        render(record)
    }

    private func render(_ record: SessionRecord?) {
        updatePolling(for: record)
        // An idle keyboard does not need a meter or a subtitle, and the space
        // they used to occupy is better spent on the keys.
        let isSessionActive = record.map { !$0.state.isTerminal } ?? false
        if isSessionActive != hasActiveSession {
            hasActiveSession = isSessionActive
            applyLayoutMetrics()
        }
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
            .targetContextChanged,
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
                ? "Gateway unavailable"
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
            statusLabel.text = "Transcript is waiting"
            languageLabel.text = "Return to that field, or insert it here"
            recordingDot.backgroundColor = .systemOrange
            meterView.activeColor = .systemOrange
            setPrimaryButton(
                title: "Insert here",
                symbol: "text.badge.plus",
                color: .systemGreen,
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

        keyGrid.delegate = self
        let stack = UIStackView(arrangedSubviews: [dictationCard, toolbarStack, keyGrid])
        stack.axis = .vertical
        stack.spacing = Self.chromeSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Key previews for the top row draw above the grid's own bounds.
        stack.clipsToBounds = false
        view.clipsToBounds = false
        view.addSubview(stack)

        let cardHeight = dictationCard.heightAnchor.constraint(equalToConstant: 76)
        let toolbarHeight = toolbarStack.heightAnchor.constraint(equalToConstant: 34)
        let gridHeight = keyGrid.heightAnchor.constraint(equalToConstant: 202)
        let keyboardHeight = view.heightAnchor.constraint(equalToConstant: 326)
        keyboardHeight.priority = UILayoutPriority(999)
        cardHeightConstraint = cardHeight
        toolbarHeightConstraint = toolbarHeight
        gridHeightConstraint = gridHeight
        keyboardHeightConstraint = keyboardHeight

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.chromeInset),
            stack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Self.chromeInset
            ),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.chromeInset),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: view.bottomAnchor,
                constant: -Self.chromeInset
            ),
            cardHeight,
            toolbarHeight,
            gridHeight,
            keyboardHeight,
        ])
        applyTheme()
        applyLayoutMetrics()
        applyDocumentTraits()
        updateAutomaticShift()
    }

    private static let chromeSpacing: CGFloat = 7
    private static let chromeInset: CGFloat = 6

    /// Sizes everything from the current traits instead of a single portrait
    /// iPhone constant, and gives the status card only as much room as the
    /// current state actually needs.
    private func applyLayoutMetrics() {
        let metrics = KeyboardMetrics.resolved(for: traitCollection)
        keyGrid.metrics = metrics

        let isCompactHeight = traitCollection.verticalSizeClass == .compact
        let cardHeight: CGFloat = isCompactHeight ? 46 : (hasActiveSession ? 76 : 54)
        let toolbarHeight: CGFloat = isCompactHeight ? 30 : 34
        let showsDetail = cardHeight >= 70
        meterView.isHidden = !showsDetail
        languageLabel.isHidden = !showsDetail

        cardHeightConstraint?.constant = cardHeight
        toolbarHeightConstraint?.constant = toolbarHeight
        gridHeightConstraint?.constant = metrics.gridHeight
        keyboardHeightConstraint?.constant = 2 * Self.chromeInset
            + cardHeight
            + toolbarHeight
            + metrics.gridHeight
            + 2 * Self.chromeSpacing
        view.setNeedsLayout()
    }

    /// Mirrors the traits of the field being typed into. Without this the
    /// keyboard capitalizes usernames, labels every action "return", and renders
    /// a light theme inside a dark-appearance field.
    private func applyDocumentTraits() {
        let proxy = textDocumentProxy
        keyGrid.showsGlobeKey = needsInputModeSwitchKey
        let returnKeyType = proxy.returnKeyType ?? .default
        keyGrid.returnKeyTitle = Self.returnKeyTitle(for: returnKeyType)
        keyGrid.returnKeyIsProminent = returnKeyType != .default
        keyGrid.leadingPunctuation = Self.leadingPunctuation(for: proxy.keyboardType ?? .default)
        applyTheme()
    }

    private static func returnKeyTitle(for type: UIReturnKeyType) -> String {
        switch type {
        case .go: "Go"
        case .google, .yahoo, .search: "Search"
        case .join: "Join"
        case .next: "Next"
        case .route: "Route"
        case .send: "Send"
        case .done: "Done"
        case .emergencyCall: "Emergency"
        case .continue: "Continue"
        default: "return"
        }
    }

    /// Email and web fields put their most-used separator where the comma sits,
    /// the way the system keyboard does.
    private static func leadingPunctuation(for type: UIKeyboardType) -> String {
        switch type {
        case .emailAddress: "@"
        case .URL, .webSearch: "/"
        default: ","
        }
    }

    private static func initialPlane(for type: UIKeyboardType) -> KeyPlane {
        switch type {
        case .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad, .numbersAndPunctuation:
            .numbers
        default:
            .letters
        }
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
        configuration.baseBackgroundColor = palette.toolbarControl
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
        // `render` runs on every poll tick. Rebuilding the menu and button
        // configuration each time churns allocations and re-lays out the toolbar
        // for state that almost never changes.
        guard renderedStyle != selected || renderedStyleEnabled != enabled else { return }
        renderedStyle = selected
        renderedStyleEnabled = enabled
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
        configuration.baseBackgroundColor = palette.toolbarControl
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
        defer { primaryButton.accessibilityValue = statusLabel.text }
        guard renderedPrimary?.title != title
            || renderedPrimary?.symbol != symbol
            || renderedPrimary?.color != color
            || renderedPrimary?.enabled != enabled
        else { return }
        renderedPrimary = (title, symbol, color, enabled)
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
        primaryButton.accessibilityHint = switch title {
        case "Dictate": "Opens Local Flow and starts private dictation."
        case "Finish": "Stops recording and starts transcription."
        case "Insert": "Inserts the transcript at the cursor."
        case "Insert here": "Inserts the waiting transcript into this field instead."
        case "Open app": "Opens Local Flow to continue."
        default: nil
        }
    }

    /// Fields can request a dark keyboard inside a light app, so the appearance
    /// comes from the document first and only falls back to the system trait.
    private var prefersDarkAppearance: Bool {
        switch textDocumentProxy.keyboardAppearance ?? .default {
        case .dark: true
        case .light: false
        default: traitCollection.userInterfaceStyle == .dark
        }
    }

    private func applyTheme() {
        palette = KeyboardPalette(isDark: prefersDarkAppearance)
        view.backgroundColor = palette.background
        inputView?.backgroundColor = palette.background
        dictationCard.backgroundColor = palette.card
        dictationCard.layer.borderColor = palette.cardBorder.cgColor
        statusLabel.textColor = palette.label
        languageLabel.textColor = palette.secondaryLabel
        keyGrid.palette = palette
        renderedStyle = nil
        renderedPrimary = nil
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

    /// Autocapitalization follows the field's own request. A username or URL
    /// field asks for none, and forcing sentence case there produced input the
    /// user had to correct on every word.
    private func updateAutomaticShift() {
        let proxy = textDocumentProxy
        let requested = proxy.autocapitalizationType ?? .sentences
        guard requested != .allCharacters else {
            keyGrid.shiftState = .locked
            return
        }
        // A user-engaged caps lock outranks any automatic decision.
        guard keyGrid.shiftState != .locked else { return }

        let before = proxy.documentContextBeforeInput ?? ""
        switch requested {
        case .none:
            keyGrid.shiftState = .off
        case .words:
            keyGrid.shiftState = before.isEmpty || before.last?.isWhitespace == true ? .on : .off
        default:
            let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
            let startsSentence = trimmed.isEmpty
                || before.hasSuffix("\n")
                || before.hasSuffix(". ")
                || before.hasSuffix("! ")
                || before.hasSuffix("? ")
            keyGrid.shiftState = startsSentence ? .on : .off
        }
    }
}

extension KeyboardViewController: KeyGridViewDelegate {}

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
