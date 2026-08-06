import UIKit

final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    private let store = SharedStore.shared
    private var activeSessionID: UUID?
    private var pollingTimer: Timer?
    private var appLaunchFallbackTask: Task<Void, Never>?
    private var lastInsertedText: String?
    private var isPerformingInsertion = false
    private var lastSpaceInsertedAt: Date?
    /// Observed by this keyboard instance rather than read from the record: the
    /// record's timestamps cover the whole session, including the hand-off to
    /// the app, which is not what the user is watching tick up.
    private var recordingStartedAt: Date?
    private var lastRenderedState: SessionState?
    private var hasRendered = false
    private var announcesStateChanges = false
    private var lastPublishedAt: Date?
    private static let statusRepublishInterval: TimeInterval = 10
    private var isBarExpanded = false
    private var lastDocumentID: String?
    /// The document the active session inserts into, as observed by this
    /// keyboard instance. iOS issues a fresh `documentIdentifier` when the
    /// keyboard is torn down and recreated, so the identifier stored in the
    /// session record is only comparable while the instance that captured it
    /// is still alive; each instance records its own target.
    private var sessionTargetDocumentID: String?
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

    private lazy var dictationBar = DictationBarView(
        metrics: DictationBarMetrics.resolved(for: traitCollection),
        palette: palette
    )
    private lazy var keyGrid = KeyGridView(
        metrics: KeyboardMetrics.resolved(for: traitCollection),
        palette: palette
    )
    private var keyboardHeightConstraint: NSLayoutConstraint?
    private var barHeightConstraint: NSLayoutConstraint?
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
        publishKeyboardStatus()
        render(nil)
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A recreated extension instance can inherit a session the previous one
        // started, so scan once on appear and let `render` decide about polling.
        applyDocumentTraits()
        publishKeyboardStatus()
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A session found before the keyboard is on screen is work already in
        // flight being restored, not something that just happened to the user,
        // and it must not arrive as a buzz in their hand.
        announcesStateChanges = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollingTimer?.invalidate()
        pollingTimer = nil
        appLaunchFallbackTask?.cancel()
    }

    /// The containing app has no API for whether this keyboard is installed or
    /// holds Full Access, so this write is the only evidence of either — and
    /// guided setup sits waiting for it. iOS reuses extension instances, so
    /// `viewDidLoad` alone can leave the app watching a status from an earlier
    /// launch; republishing on every appearance closes that gap, throttled so
    /// that returning to the keyboard repeatedly is not a stream of file writes.
    private func publishKeyboardStatus() {
        let now = Date()
        if let lastPublishedAt,
           now.timeIntervalSince(lastPublishedAt) < Self.statusRepublishInterval
        {
            return
        }
        lastPublishedAt = now
        try? store.saveKeyboardStatus(
            KeyboardStatus(lastSeenAt: now, hasFullAccess: hasFullAccess)
        )
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

    // MARK: - Dictation actions

    /// Each action arrives already decided by the rendered model, so a button
    /// can only ever do what its own label promised.
    private func perform(_ action: DictationAction) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        switch action {
        case .start: startSession()
        case .finish: finishRecording()
        case .insert: insertTranscript(force: false)
        case .insertHere: insertTranscript(force: true)
        case .openApp: resumeHandoff()
        case .retry: retryTranscription()
        case .cancel: cancelSession()
        case .undo: undoInsertion()
        }
    }

    private func finishRecording() {
        guard let id = activeSessionID,
              var record = try? store.load(id),
              record.state == .recording
        else { return }
        transition(&record, to: .finalizing)
    }

    private func insertTranscript(force: Bool) {
        guard let id = activeSessionID, var record = try? store.load(id) else { return }
        // Tapping "Insert here" is an explicit request for the transcript in
        // whatever field the cursor is in now, so the target guard is bypassed
        // rather than leaving the transcript unreachable.
        if force, record.state == .targetContextChanged {
            transition(&record, to: .readyToInsert)
        }
        insert(&record, force: force)
    }

    private func resumeHandoff() {
        guard let id = activeSessionID, let record = try? store.load(id) else {
            startSession()
            return
        }
        openContainingApp(for: record)
    }

    private func cancelSession() {
        guard let id = activeSessionID, var record = try? store.load(id) else { return }
        transition(&record, to: .canceled)
    }

    private func retryTranscription() {
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
                    self?.dictationBar.flash("Open Local Flow to retry the preserved recording.")
                }
            }
        }
    }

    private func undoInsertion() {
        guard let inserted = lastInsertedText,
              textDocumentProxy.documentContextBeforeInput?.hasSuffix(inserted) == true
        else {
            dictationBar.flash("The cursor moved, so undo is no longer available.")
            lastInsertedText = nil
            refresh()
            return
        }
        inserted.forEach { _ in textDocumentProxy.deleteBackward() }
        lastInsertedText = nil
        refresh()
        dictationBar.flash("The last insertion was removed.")
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
        refresh()
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
            sessionTargetDocumentID = nil
        } catch {
            // A session still moving through the pipeline resolves on its own.
        }
    }

    private func startSession() {
        guard hasFullAccess else {
            dictationBar.flash("Turn on Full Access for Local Flow in Keyboard settings.")
            return
        }
        discardParkedSession()
        var record = SessionRecord(
            state: .idle,
            sourceDocumentID: currentDocumentID,
            language: KeyboardPreferences.effectiveTranscriptionLanguage.rawValue,
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
            sessionTargetDocumentID = record.sourceDocumentID
            render(record)
            if let availability = try? store.loadQuickDictationAvailability(),
               availability.isReady()
            {
                dictationBar.flash("Starting with Quick Dictation…")
                scheduleContainingAppFallback(for: record)
            } else {
                openContainingApp(for: record)
            }
        } catch {
            dictationBar.flash("Could not create a shared session.")
        }
    }

    /// A transcript belongs to the field it was dictated for. The comparison
    /// uses the target this instance captured, never the identifier stored in
    /// the record: identifiers are regenerated across keyboard relaunches, so
    /// a stored one from a previous instance would block every insertion. iOS
    /// may also withhold the identifier, so only a confirmed mismatch between
    /// two known identifiers blocks insertion; an unknown identifier must not
    /// strand a transcript the user is waiting for.
    private func documentMatchesSessionTarget() -> Bool {
        guard let target = sessionTargetDocumentID,
              let current = currentDocumentID
        else { return true }
        return target == current
    }

    private func insert(_ record: inout SessionRecord, force: Bool = false) {
        guard !isPerformingInsertion else { return }
        guard let transcript = record.transcript, !transcript.isEmpty else { return }
        guard force || documentMatchesSessionTarget() else {
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
            sessionTargetDocumentID = nil
            render(record)
        } catch {
            dictationBar.flash("Insertion was interrupted; text will not be inserted twice.")
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
                if opened { return }
                if var waiting = try? self.store.load(record.sessionID),
                   waiting.state == .launchingApp
                {
                    self.transition(&waiting, to: .awaitingReturn)
                }
                self.dictationBar.flash(
                    "Open Local Flow manually; the recording request is waiting."
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
            dictationBar.flash("The session changed. Please try again.")
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
        // A recreated instance cannot compare its identifiers with ones the
        // previous instance stored, so the field the user has returned to
        // becomes the session's insertion target.
        sessionTargetDocumentID = currentDocumentID
        handle(recent)
    }

    private func handle(_ incoming: SessionRecord) {
        var record = incoming
        // Returning to the field the transcript was dictated for re-arms an
        // insertion that was parked when the cursor moved elsewhere.
        if record.state == .targetContextChanged, documentMatchesSessionTarget() {
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
        let state = record?.state ?? .idle
        let model = DictationBarModel.make(
            DictationContext(
                state: state,
                hasFullAccess: hasFullAccess,
                transcript: record?.transcript,
                errorMessage: record?.error?.message,
                autoInsertsTranscripts: KeyboardPreferences.autoInsertTranscripts,
                canRetry: record?.canRetry == true,
                // Undo is offered only while the transcript is still the tail of
                // the document, and only once the session it came from is over.
                canUndo: lastInsertedText != nil
            )
        )

        // An idle keyboard needs no meter and no subtitle, and the height they
        // would occupy is better spent on the keys.
        if model.isExpanded != isBarExpanded {
            isBarExpanded = model.isExpanded
            applyLayoutMetrics(animated: hasRendered)
        }
        updateElapsedTime(for: state)
        if state == .recording {
            dictationBar.push(meterLevel: record?.meterLevel ?? 0)
        }
        dictationBar.apply(model, animated: hasRendered)
        announceStateChange(to: state)
        hasRendered = true
    }

    private func updateElapsedTime(for state: SessionState) {
        guard state == .recording else {
            recordingStartedAt = nil
            dictationBar.setElapsed(nil)
            return
        }
        let start = recordingStartedAt ?? Date()
        recordingStartedAt = start
        dictationBar.setElapsed(Date().timeIntervalSince(start))
    }

    /// The keyboard is often not the view the user is looking at while a
    /// transcript is being produced, so the milestones announce themselves.
    private func announceStateChange(to state: SessionState) {
        guard state != lastRenderedState else { return }
        lastRenderedState = state
        guard announcesStateChanges, hasFullAccess else { return }
        switch state {
        case .recording:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .readyToInsert:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .permissionDenied, .serverUnavailable, .uploadFailedRecoverable,
             .transcriptionFailedRecoverable, .transcriptionFailedPermanent:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        default:
            break
        }
    }

    private func configureUI() {
        dictationBar.delegate = self
        keyGrid.delegate = self
        let stack = UIStackView(arrangedSubviews: [dictationBar, keyGrid])
        stack.axis = .vertical
        stack.spacing = Self.chromeSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Key previews for the top row draw above the grid's own bounds.
        stack.clipsToBounds = false
        view.clipsToBounds = false
        view.addSubview(stack)

        let barMetrics = DictationBarMetrics.resolved(for: traitCollection)
        let barHeight = dictationBar.heightAnchor.constraint(
            equalToConstant: barMetrics.height(expanded: false)
        )
        let gridHeight = keyGrid.heightAnchor.constraint(equalToConstant: 202)
        let keyboardHeight = view.heightAnchor.constraint(equalToConstant: 326)
        keyboardHeight.priority = UILayoutPriority(999)
        barHeightConstraint = barHeight
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
            barHeight,
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
    /// iPhone constant, and gives the dictation bar only as much room as the
    /// current state actually needs.
    private func applyLayoutMetrics(animated: Bool = false) {
        let metrics = KeyboardMetrics.resolved(for: traitCollection)
        let barMetrics = DictationBarMetrics.resolved(for: traitCollection)
        keyGrid.metrics = metrics
        dictationBar.metrics = barMetrics

        let barHeight = barMetrics.height(expanded: isBarExpanded)
        barHeightConstraint?.constant = barHeight
        gridHeightConstraint?.constant = metrics.gridHeight
        keyboardHeightConstraint?.constant = 2 * Self.chromeInset
            + barHeight
            + metrics.gridHeight
            + Self.chromeSpacing

        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            view.setNeedsLayout()
            return
        }
        // The host app resizes around the keyboard, so the expansion has to be
        // a settle rather than a jump.
        UIView.animate(
            withDuration: 0.34,
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.view.layoutIfNeeded()
        }
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
        dictationBar.palette = palette
        keyGrid.palette = palette
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

extension KeyboardViewController: DictationBarViewDelegate {
    func dictationBar(_ bar: DictationBarView, didTrigger action: DictationAction) {
        perform(action)
    }

    func dictationBarDidChangePreferences(_ bar: DictationBarView) {
        refresh()
    }
}
