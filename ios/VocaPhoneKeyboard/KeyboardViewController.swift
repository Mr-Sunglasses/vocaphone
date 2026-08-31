import os
import UIKit

final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    private let store = SharedStore.shared
    private var activeSessionID: UUID?
    private var pollingTimer: Timer?
    private var pollingInterval: TimeInterval?
    private var darwinObservations: [VocaPhoneDarwinObservation] = []
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
    private var lastPublishedFullAccess: Bool?
    private static let statusRepublishInterval: TimeInterval = 10
    private var isBarExpanded = false
    private var barLayout = DictationBarLayout.status
    private var lastDocumentID: String?
    /// The document the active session inserts into, as observed during this
    /// appearance of the keyboard. iOS issues a fresh `documentIdentifier` when
    /// the keyboard is torn down and recreated, and can reissue one across an
    /// app switch, so an identifier only means anything for as long as the
    /// keyboard has been continuously on screen. It is released in
    /// ``viewWillAppear(_:)`` and re-latched from the field the user has
    /// returned to.
    private var sessionTargetDocumentID: String?
    private var palette = KeyboardPalette(isDark: false)
    private lazy var typing = TypingEngine()
    /// The record the bar is currently drawn from, so a strip update can
    /// re-render without another read of the shared container. A file read per
    /// keystroke is exactly the cost typing intelligence must not add.
    private var lastRecord: SessionRecord?

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

    /// Read once per appearance rather than on every layout pass: it can only
    /// change in the containing app, which means this extension has been torn
    /// down or at least sent off screen in between.
    private var heightPreference = KeyboardPreferences.keyboardHeight

    private lazy var dictationBar = DictationBarView(
        metrics: DictationBarMetrics.resolved(
            for: traitCollection,
            preference: heightPreference
        ),
        palette: palette
    )
    /// Built the first time it is opened, never at launch.
    ///
    /// A `UICollectionView` and ten category buttons is not much on its own, but
    /// a keyboard extension is killed somewhere around 45–60 MB and this is a
    /// panel most sessions never open. Everything the keyboard needs to *appear*
    /// comes first; everything else waits to be asked for.
    private var emojiPanel: EmojiPanelView?
    private lazy var keyGrid = KeyGridView(
        metrics: KeyboardMetrics.resolved(for: traitCollection, preference: heightPreference),
        palette: palette
    )
    private var keyboardHeightConstraint: NSLayoutConstraint?
    private var barHeightConstraint: NSLayoutConstraint?
    private var gridHeightConstraint: NSLayoutConstraint?
    private var emojiPanelHeightConstraint: NSLayoutConstraint?
    private var keyboardStack: UIStackView?

    var enableInputClicksWhenVisible: Bool { true }

    /// iOS decides whether to add its Face ID dictation button before loading
    /// the keyboard's view, so this must be set during controller creation.
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        hasDictationKey = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        hasDictationKey = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Reassert the value after UIKit has completed controller creation.
        hasDictationKey = true
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
        typing.onStrip = { [weak self] strip in
            guard let self else { return }
            renderStrip(strip)
            noteAvailableMemory(.firstCandidates)
        }
        typing.onWordListLoaded = { [weak self] list in
            self?.keyGrid.swipeWordList = list
        }
        // The language half of the touch model. Straight through to the grid,
        // which hands it to the hit map — nothing here interprets it.
        typing.onNextCharacters = { [weak self] weights in
            self?.keyGrid.nextCharacterLikelihood = weights
        }
        // The user's own text replacements and contact names. Requested once per
        // instance; if Full Access is off it simply comes back empty.
        typing.loadLexicon(from: self)
        KeyboardHaptics.shared.attach(to: view, hasFullAccess: hasFullAccess)
        render(nil)
        refresh()
        noteAvailableMemory(.launched)
    }

    /// How much room the extension has left, sampled at the two moments that
    /// decide whether it survives.
    ///
    /// A keyboard extension is killed somewhere around 45–60 MB, and a jetsam
    /// looks to its owner like a keyboard that will not open — there is no
    /// crash report, no alert, just the previous keyboard coming back. So the
    /// budget is measured rather than assumed. A count of bytes and nothing
    /// else: no text, ever.
    enum MemorySample {
        case launched
        case firstCandidates
    }

    private var sampledMoments: Set<String> = []

    private func noteAvailableMemory(_ moment: MemorySample) {
        let key = "\(moment)"
        guard sampledMoments.insert(key).inserted else { return }
        let availableMB = Int(os_proc_available_memory() / (1024 * 1024))
        DiagnosticLog.record(
            .keyboardShown,
            metadata: .megabytesAvailable(availableMB)
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Extension controllers can be reused across host fields and apps.
        hasDictationKey = true
        // A recreated extension instance can inherit a session the previous one
        // started, so scan once on appear and let `render` decide about polling.
        applyDocumentTraits()
        // A new appearance is a new field as far as this keyboard can tell.
        //
        // The insertion target was previously kept for the life of the
        // extension instance, which made automatic insertion depend on
        // something the user cannot see: whether iOS killed the keyboard during
        // the hand-off. A killed extension came back, adopted the session and
        // targeted whatever field the cursor was now in, so insertion always
        // worked. A surviving one still held the identifier captured before the
        // hand-off, and iOS reissues those across an app switch — so the same
        // dictation, in the same field, silently parked itself behind an Insert
        // button instead. Same action, two outcomes, decided by memory
        // pressure.
        //
        // Releasing the target here makes both paths agree on the permissive
        // one, which is what shipped for every killed extension already. The
        // guard keeps the case it can actually observe: a cursor that moves to
        // another field *while the keyboard is on screen* still parks the
        // transcript rather than following the cursor.
        sessionTargetDocumentID = nil
        installDarwinObservers()
        publishKeyboardStatus()
        // Full Access can be granted or revoked in Settings while this instance
        // stays alive, and a warm engine is what makes the first key of the
        // session land as a tap rather than as nothing.
        KeyboardHaptics.shared.attach(to: view, hasFullAccess: hasFullAccess)
        applyHeightPreferenceIfChanged()
        refresh()
    }

    /// Picks up a height chosen in the containing app. iOS keeps extension
    /// instances alive between appearances, so without this the new height would
    /// wait for the keyboard process to be recycled.
    private func applyHeightPreferenceIfChanged() {
        let preference = KeyboardPreferences.keyboardHeight
        guard preference != heightPreference else { return }
        heightPreference = preference
        applyLayoutMetrics()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // UIKit can finalize a changed Full Access setting after the earlier
        // appearance callbacks. This is the last lifecycle point before guided
        // setup expects the extension to prove its state.
        publishKeyboardStatus()
        KeyboardHaptics.shared.attach(to: view, hasFullAccess: hasFullAccess)
        // A session found before the keyboard is on screen is work already in
        // flight being restored, not something that just happened to the user,
        // and it must not arrive as a buzz in their hand.
        announcesStateChanges = true
        NSLog("""
        DIAG ourView=\(view.bounds.size) \
        super=\(String(describing: view.superview?.bounds.size)) \
        superSuper=\(String(describing: view.superview?.superview?.bounds.size)) \
        inputView=\(String(describing: inputView?.bounds.size)) \
        needsSwitchKey=\(needsInputModeSwitchKey) \
        window=\(String(describing: view.window?.bounds.size))
        """)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollingTimer?.invalidate()
        pollingTimer = nil
        pollingInterval = nil
        darwinObservations.forEach { $0.invalidate() }
        darwinObservations.removeAll()
        appLaunchFallbackTask?.cancel()
        // A held key or an open accent popover must not survive the keyboard
        // being dismissed; iOS does not reliably cancel those touches for us.
        keyGrid.endActiveInteractions()
        // A prepared generator keeps the Taptic Engine powered for a second or
        // two, which a dismissed keyboard has no business spending.
        KeyboardHaptics.shared.release()
    }

    /// The containing app has no API for whether this keyboard is installed or
    /// holds Full Access, so this write is the only evidence of either — and
    /// guided setup sits waiting for it. iOS reuses extension instances, so
    /// `viewDidLoad` alone can leave the app watching a status from an earlier
    /// launch; republishing on every appearance closes that gap, throttled so
    /// that returning to the keyboard repeatedly is not a stream of file writes.
    private func publishKeyboardStatus() {
        let now = Date()
        guard KeyboardStatusPublication.shouldPublish(
            lastPublishedAt: lastPublishedAt,
            lastPublishedFullAccess: lastPublishedFullAccess,
            fullAccess: hasFullAccess,
            now: now,
            minimumInterval: Self.statusRepublishInterval
        ) else {
            return
        }
        lastPublishedAt = now
        lastPublishedFullAccess = hasFullAccess
        try? store.saveKeyboardStatus(
            KeyboardStatus(lastSeenAt: now, hasFullAccess: hasFullAccess)
        )
        DiagnosticLog.record(
            .keyboardShown,
            metadata: .fullAccess(hasFullAccess)
        )
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        documentEvent { handleTextChange() }
    }

    /// Runs after every insertion this keyboard makes, which makes it the single
    /// hottest place in the extension for a redundant hop into the host process.
    /// One snapshot, shared by everything below.
    private func handleTextChange() {
        let snapshot = document
        // Moving to a different field brings different traits with it, and the
        // plane should reset so a number pad never leaves the user on letters.
        let documentID = currentDocumentID
        if documentID != lastDocumentID {
            lastDocumentID = documentID
            lastSpaceInsertedAt = nil
            applyDocumentTraits()
            // A waiting transcript parks itself when the cursor leaves its field
            // and re-arms when it comes back. Both were left to the next poll,
            // so the bar could still offer Insert for a field the user had
            // already left, and stayed on "Waiting for its own field" for over a
            // second after they returned to it.
            if activeSessionID != nil { refresh() }
        } else {
            // Same field, but something moved the cursor or edited the text
            // without going through this keyboard. The document wins.
            typing.reconcile(document: snapshot)
        }
        updateReturnKeyEnablement(for: snapshot)
        updateAutomaticShift(for: snapshot)
    }

    // MARK: - Dictation actions

    /// Each action arrives already decided by the rendered model, so a button
    /// can only ever do what its own label promised.
    private func perform(_ action: DictationAction) {
        KeyboardHaptics.shared.action()
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
        DiagnosticLog.record(.finishRequested)
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
                    self?.dictationBar.flash("Open vocaphone to retry the preserved recording.")
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
        documentEvent { handle(output) }
    }

    private func handle(_ output: KeyboardOutput) {
        switch output {
        case let .text(text):
            if let substitution = SmartPunctuation.substitution(
                for: text,
                before: document.before ?? "",
                traits: smartPunctuation
            ) {
                for _ in 0..<substitution.deletions { textDocumentProxy.deleteBackward() }
                textDocumentProxy.insertText(substitution.insertion)
                typing.insert(substitution.insertion, document: refreshDocument())
            } else if Self.isBoundary(text) {
                commitComposition(followedBy: text)
            } else {
                textDocumentProxy.insertText(text)
                typing.insert(text, document: refreshDocument())
            }
            lastSpaceInsertedAt = nil
            releaseUndoIfDetached()
        case .space:
            insertSpace()
        case .newline:
            commitComposition(followedBy: "\n")
            lastSpaceInsertedAt = nil
            releaseUndoIfDetached()
        case .deleteBackward:
            deleteBackward()
            lastSpaceInsertedAt = nil
            releaseUndoIfDetached()
        case .deleteWord:
            deleteWordBackward()
            typing.resetComposition(document: refreshDocument())
            releaseUndoIfDetached()
        case .emojiPanel:
            showEmojiPanel(true)
        case let .swipeWord(word, alternates):
            // A swiped word arrives whole. It is never autocorrected — the
            // recogniser already chose from the dictionary — and the losers go
            // in the strip so one tap can replace it.
            let cased = keyGrid.shiftState.isUppercase
                ? word.prefix(1).uppercased() + word.dropFirst()
                : word
            textDocumentProxy.insertText(cased + " ")
            refreshDocument()
            typing.noteSwipeWord(cased, alternates: alternates)
            lastSpaceInsertedAt = nil
            releaseUndoIfDetached()
            updateAutomaticShift()
        case let .moveCursor(offset):
            textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            lastSpaceInsertedAt = nil
            // The cursor is somewhere else now, so whatever was being composed
            // belongs to a different part of the document.
            typing.reconcile(document: refreshDocument())
            releaseUndoIfDetached()
        case let .moveCursorLine(lines):
            moveCursorByLines(lines)
            lastSpaceInsertedAt = nil
            typing.reconcile(document: refreshDocument())
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

    /// Swaps the key grid for the emoji panel, in the space the grid already
    /// occupies. The keyboard's height does not change: a panel that grew the
    /// keyboard would cost the user more of the app they are typing into than
    /// switching to the system emoji keyboard does.
    private func showEmojiPanel(_ showing: Bool) {
        guard showing || emojiPanel != nil else { return }
        let panel = showing ? makeEmojiPanelIfNeeded() : emojiPanel
        guard let panel else { return }
        guard panel.isHidden == showing else { return }
        keyGrid.endActiveInteractions()
        keyGrid.isHidden = showing
        panel.isHidden = !showing
        panel.palette = palette
        panel.metrics = KeyboardMetrics.resolved(
            for: traitCollection,
            preference: heightPreference
        )
    }

    private func makeEmojiPanelIfNeeded() -> EmojiPanelView? {
        if let emojiPanel { return emojiPanel }
        let metrics = KeyboardMetrics.resolved(for: traitCollection, preference: heightPreference)
        let panel = EmojiPanelView(palette: palette, metrics: metrics)
        panel.delegate = self
        panel.isHidden = true
        keyboardStack?.addArrangedSubview(panel)
        let height = panel.heightAnchor.constraint(equalToConstant: metrics.gridHeight)
        height.isActive = true
        emojiPanelHeightConstraint = height
        emojiPanel = panel
        // Four thousand lines, parsed off the main actor, the first time anyone
        // asks for an emoji — and never if they do not.
        Task.detached(priority: .userInitiated) {
            let catalog = EmojiCatalog.load(from: Bundle(for: KeyboardViewController.self))
            await MainActor.run { [weak self] in self?.emojiPanel?.catalog = catalog }
        }
        return panel
    }

    /// The text either side of the cursor, read once and reused for the rest of
    /// the event.
    ///
    /// Every read of `documentContextBeforeInput` is a synchronous hop into the
    /// host application. A single keystroke used to make six or seven of them:
    /// smart punctuation, the composer, the undo check, then `textDidChange`
    /// coming back for the document identifier, the composer again, and
    /// autocapitalization. On a slow host that is most of a frame spent asking
    /// the same question.
    private func readDocument() -> DocumentSnapshot {
        DocumentSnapshot(
            before: textDocumentProxy.documentContextBeforeInput,
            after: textDocumentProxy.documentContextAfterInput
        )
    }

    /// The snapshot taken at the start of the event currently being handled.
    ///
    /// Held for the duration of one call into this controller and cleared after
    /// it, so nothing can accidentally read a snapshot from the *previous*
    /// keystroke: stale context here is a wrong autocorrect, not a slow one.
    private var currentDocument: DocumentSnapshot?

    /// The event's snapshot if one has been established, and a fresh read
    /// otherwise.
    ///
    /// Deliberately does *not* cache. It used to, which meant any caller
    /// anywhere could quietly establish an event snapshot — and
    /// `applyDocumentTraits`, reached from `viewWillAppear`, is not inside an
    /// event and has no `defer` to clear one. The snapshot it left behind was
    /// then reused by the next keystroke as though it described the document
    /// now. Only the entry points below may set it, and each of them clears it
    /// on the way out.
    private var document: DocumentSnapshot {
        currentDocument ?? readDocument()
    }

    /// Runs `body` as one document event: one snapshot taken at the start,
    /// released at the end.
    ///
    /// A helper rather than a `defer` written out at each entry point, because
    /// writing it out is exactly what gets forgotten. `applyDocumentTraits` did,
    /// and left a snapshot from `viewWillAppear` for the next keystroke to read
    /// as though it described the document now; the emoji panel's handlers did
    /// too, and left one from the emoji they had just inserted. Both are the
    /// same mistake, and neither is possible through here.
    @discardableResult
    private func documentEvent<T>(_ body: () -> T) -> T {
        currentDocument = readDocument()
        defer { currentDocument = nil }
        return body()
    }

    /// Re-reads the document after this keyboard has changed it. The insertion
    /// has already happened, so the cached snapshot no longer describes what the
    /// composer is looking at.
    @discardableResult
    private func refreshDocument() -> DocumentSnapshot {
        let snapshot = readDocument()
        currentDocument = snapshot
        return snapshot
    }

    /// Re-read per keystroke rather than cached: the field can change its own
    /// traits, and the cost is two property reads.
    private var smartPunctuation: SmartPunctuation.Traits {
        SmartPunctuation.Traits.resolve(
            for: textDocumentProxy,
            enabled: KeyboardPreferences.smartPunctuationEnabled
        )
    }

    /// The characters that end a word and are therefore the moment an
    /// autocorrect may fire.
    static func isBoundary(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        return ".,!?;:".contains(character)
    }

    /// Ends the current word, applying a pending autocorrect if there is one.
    ///
    /// The rewrite is *n* deletions and one insertion, because iOS gives a
    /// keyboard extension no composing region and no atomic replace. They all
    /// happen here, in one turn, so the host never renders a half-deleted word —
    /// and never while a dictation insertion is in flight, which is what
    /// `isPerformingInsertion` guards.
    private func commitComposition(followedBy boundary: String) {
        let typed = typing.composer.text
        if !typed.isEmpty,
           !isPerformingInsertion,
           typing.composer.isAutocorrectable,
           let correction = typing.strip.autocorrection
        {
            let replacement = TypingCandidates.matchingCase(
                of: typed,
                applyingTo: correction
            )
            let rewrite = typing.composer.rewrite(to: replacement)
            for _ in 0..<rewrite.deletions { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(rewrite.insertion + boundary)
            // Order matters and used to be the other way round. Feeding the
            // boundary through the engine clears any pending revert, so noting
            // the correction first meant it was wiped by the very space that
            // applied it — Delete had nothing to restore, and undo-autocorrect,
            // the behaviour people rely on without knowing its name, silently
            // did nothing at all.
            typing.insert(boundary, document: refreshDocument())
            typing.noteCorrection(typed: typed, replacement: replacement, boundary: boundary)
            // The correction is the one keyboard action a user may not have
            // noticed, so it announces itself — and only it.
            UIAccessibility.post(
                notification: .announcement,
                argument: "Corrected to \(replacement)"
            )
            return
        }
        if !boundary.isEmpty { textDocumentProxy.insertText(boundary) }
        if !typed.isEmpty { typing.noteCompletedWord(typed) }
        typing.insert(boundary.isEmpty ? " " : boundary, document: refreshDocument())
    }

    /// Delete, which is also how an autocorrect is undone.
    ///
    /// Pressing Delete as the very next action after a correction restores what
    /// was typed, exactly, and marks the word as the user's for the rest of the
    /// document. This is the behaviour people rely on without knowing its name,
    /// and getting it wrong is how a keyboard becomes something to fight.
    private func deleteBackward() {
        guard !revertPendingCorrection() else { return }
        textDocumentProxy.deleteBackward()
        typing.deleteBackward(document: refreshDocument())
    }

    /// Puts back exactly what the user typed, if an autocorrect is still
    /// standing. Reports whether it did.
    ///
    /// Reached two ways, which is the point of it being one function: pressing
    /// Delete as the very next action, and tapping the chip the strip offers
    /// right afterwards. The system keyboard draws that offer as a bubble under
    /// the word itself; an extension is never told where the word is on screen,
    /// so the strip is the surface this keyboard can honestly put it on.
    @discardableResult
    private func revertPendingCorrection() -> Bool {
        guard let revert = typing.takeRevert(documentBefore: document.before) else { return false }
        let removals = revert.replacement.count + revert.boundary.count
        for _ in 0..<removals { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(revert.typed + revert.boundary)
        typing.reconcile(document: refreshDocument())
        UIAccessibility.post(
            notification: .announcement,
            argument: "Restored \(revert.typed)"
        )
        return true
    }

    func keyGridDidChangeShift(_ grid: KeyGridView) {}

    private func insertSpace() {
        let proxy = textDocumentProxy
        let before = document.before ?? ""
        // A second space closes the sentence instead of doubling the gap, which
        // is the iOS behaviour people type by reflex. It can never coincide with
        // a pending correction: the previous space already ended that word.
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
            typing.insert(". ", document: refreshDocument())
        } else {
            commitComposition(followedBy: " ")
            lastSpaceInsertedAt = Date()
        }
        releaseUndoIfDetached()
    }

    /// Moves the cursor a whole line up or down, keeping its column.
    ///
    /// A keyboard extension can only `adjustTextPosition(byCharacterOffset:)`,
    /// so "one line" has to be counted out in characters from the document
    /// context — which is why this lives here rather than in the grid: the grid
    /// knows the finger moved, and only the controller can see the text.
    ///
    /// Clamped to the ends. Off the top or bottom of the visible context the
    /// cursor goes to the start or end of it rather than nowhere, which is what
    /// the user is reaching for anyway.
    private func moveCursorByLines(_ lines: Int) {
        guard lines != 0 else { return }
        let snapshot = document
        let beforeLines = (snapshot.before ?? "").components(separatedBy: "\n")
        let afterLines = (snapshot.after ?? "").components(separatedBy: "\n")
        // How far into its own line the cursor sits. The last element of the
        // leading context is the part of the current line behind the cursor.
        let column = beforeLines.last?.count ?? 0
        let proxy = textDocumentProxy

        if lines < 0 {
            // Nothing above in the visible context: the start of this line is
            // the nearest thing to what was asked for, and it is where a finger
            // dragged off the top is reaching anyway.
            guard beforeLines.count > 1 else {
                if column > 0 { proxy.adjustTextPosition(byCharacterOffset: -column) }
                return
            }
            let steps = min(-lines, beforeLines.count - 1)
            let target = beforeLines.count - 1 - steps
            // Back to the start of the current line, then over each line
            // skipped along with the break that ended it.
            var offset = -column
            for index in stride(from: beforeLines.count - 2, through: target, by: -1) {
                offset -= 1 + beforeLines[index].count
            }
            // Forward into the target line, clamped to its end so a short line
            // keeps the cursor on it rather than past it.
            offset += min(column, beforeLines[target].count)
            proxy.adjustTextPosition(byCharacterOffset: offset)
        } else {
            guard afterLines.count > 1 else {
                let tail = afterLines.first?.count ?? 0
                if tail > 0 { proxy.adjustTextPosition(byCharacterOffset: tail) }
                return
            }
            let steps = min(lines, afterLines.count - 1)
            var offset = afterLines[0].count
            for index in 1..<steps {
                offset += 1 + afterLines[index].count
            }
            offset += 1 + min(column, afterLines[steps].count)
            proxy.adjustTextPosition(byCharacterOffset: offset)
        }
    }

    private func deleteWordBackward() {
        let proxy = textDocumentProxy
        guard let before = document.before, !before.isEmpty else {
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
              document.before?.hasSuffix(inserted) != true
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
            dictationBar.flash("Full Access is needed. \(DictationBarModel.fullAccessPath)")
            return
        }
        discardParkedSession()
        var record = SessionRecord(
            state: .idle,
            sourceDocumentID: currentDocumentID,
            language: KeyboardPreferences.effectiveTranscriptionLanguage.rawValue,
            style: KeyboardPreferences.writingStyle.rawValue
        )
        // Dictating into vocaphone's own field means there is nowhere to swipe
        // back to; the app needs to know so it does not cover that field with
        // hand-off instructions.
        record.startedInContainingApp = KeyboardPreferences.containingAppIsForeground
        let availability = try? store.loadQuickDictationAvailability()
        record.prefersQuickDictation = availability?.isReady() == true
        do {
            try record.transition(to: .launchingApp)
            try store.save(record)
            activeSessionID = record.sessionID
            sessionTargetDocumentID = record.sourceDocumentID
            render(record)
            if record.prefersQuickDictation == true {
                dictationBar.flash("Starting with Quick Dictation…")
                scheduleContainingAppFallback(for: record)
            } else {
                if availability != nil {
                    DiagnosticLog.record(.quickDictationStale)
                }
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
        InsertionTarget.allowsInsertion(
            target: sessionTargetDocumentID,
            current: currentDocumentID
        )
    }

    private func insert(_ record: inout SessionRecord, force: Bool = false) {
        guard !isPerformingInsertion else {
            DiagnosticLog.record(.insertionSkipped, metadata: .reason(.insertionInFlight))
            return
        }
        guard let transcript = record.transcript, !transcript.isEmpty else {
            DiagnosticLog.record(.insertionSkipped, metadata: .reason(.transcriptEmpty))
            return
        }
        guard force || documentMatchesSessionTarget() else {
            // Parked rather than inserted. Which of the two identifiers changed
            // is not knowable from here — iOS reissues them across a keyboard
            // relaunch — so the log records that it happened at all, and the
            // state change that follows records where the transcript went.
            DiagnosticLog.record(.insertionSkipped, metadata: .reason(.targetFieldChanged))
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
            DiagnosticLog.record(.insertionStarted)
            try record.transition(to: .inserting)
            try store.save(record)
            textDocumentProxy.insertText(prepared)
            lastInsertedText = prepared
            // A transcript arrives as finished text. It never becomes a
            // composition and is never autocorrected: the model that produced it
            // already had its say.
            typing.resetComposition(origin: .dictated, document: .unknown)
            try record.transition(to: .inserted)
            try store.save(record)
            try record.transition(to: .completed)
            try store.save(record)
            // A keyboard-started dictation inside vocaphone's own field is the
            // one onboarding exercise that proves the whole loop: Dictate,
            // record, transcribe and direct insertion. Do not set this for
            // keyboard sessions started in another app or for the app's
            // diagnostic microphone test.
            if record.startedInContainingApp == true, record.sourceDocumentID != "in-app-test" {
                KeyboardPreferences.hasCompletedKeyboardPractice = true
            }
            DiagnosticLog.record(.insertionCompleted)
            activeSessionID = nil
            sessionTargetDocumentID = nil
            render(record)
        } catch {
            dictationBar.flash("Insertion was interrupted; text will not be inserted twice.")
        }
    }

    private func openContainingApp(for incoming: SessionRecord) {
        appLaunchFallbackTask?.cancel()
        appLaunchFallbackTask = nil
        var record = incoming
        // A healthy standby path starts in the host app. Once this fallback runs,
        // persist the real route before opening vocaphone so the keyboard never
        // continues to promise a no-switch start after it has begun foregrounding
        // the containing app.
        if record.prefersQuickDictation == true {
            record.prefersQuickDictation = false
            try? store.save(record)
            render(record)
        }
        let sessionID = record.sessionID
        guard let url = URL(
            string: "\(AppConfiguration.urlScheme)://dictate?session=\(sessionID.uuidString)"
        ) else { return }
        openURLFromKeyboard(url) { [weak self] opened in
            DispatchQueue.main.async {
                guard let self else { return }
                if opened { return }
                if var waiting = try? self.store.load(sessionID),
                   waiting.state == .launchingApp
                {
                    self.transition(&waiting, to: .awaitingReturn)
                }
                self.dictationBar.flash(
                    "Open vocaphone manually; the recording request is waiting."
                )
            }
        }
    }

    /// Quick Dictation records without leaving the host app, so opening
    /// vocaphone is the failure path, not the plan. It fires only once the
    /// request looks genuinely unanswered: unclaimed after the short window, or
    /// claimed but still not recording by the deadline. Warming the microphone
    /// graph regularly outruns the short window on its own — a first on-device
    /// model load, or another app still letting go of the input — and switching
    /// apps there aborted dictations that were about to start.
    private func scheduleContainingAppFallback(for record: SessionRecord) {
        appLaunchFallbackTask?.cancel()
        appLaunchFallbackTask = Task { [weak self] in
            let milliseconds = Int(
                AppConfiguration.quickDictationLaunchFallbackSeconds * 1_000
            )
            let deadline = Date().addingTimeInterval(
                AppConfiguration.quickDictationClaimedLaunchDeadlineSeconds
            )
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(milliseconds))
                guard !Task.isCancelled,
                      let self,
                      let current = try? self.store.load(record.sessionID),
                      [.launchingApp, .awaitingReturn].contains(current.state)
                else { return }
                guard current.claimedAt == nil || Date() >= deadline else { continue }
                self.openContainingApp(for: current)
                return
            }
        }
    }

    private func openURLFromKeyboard(
        _ url: URL,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        // Custom keyboards don't support opening their containing app through
        // NSExtensionContext on current iOS releases. The responder chain still
        // carries the user-initiated URL request to the owning app or scene.
        if VocaPhoneOpenURLFromResponderChain(self, url) {
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

    private func installDarwinObservers() {
        guard darwinObservations.isEmpty else { return }
        darwinObservations.append(
            VocaPhoneDarwinCenter.observe(.sessionChanged) { [weak self] in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        )
        darwinObservations.append(
            VocaPhoneDarwinCenter.observe(.quickDictationChanged) { [weak self] in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        )
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
            pollingInterval = nil
            return
        }
        guard let desiredInterval = SessionPollingPolicy.interval(for: record?.state) else {
            pollingTimer?.invalidate()
            pollingTimer = nil
            pollingInterval = nil
            return
        }
        if pollingInterval != desiredInterval {
            pollingTimer?.invalidate()
            pollingTimer = nil
        }
        guard pollingTimer == nil else { return }
        let timer = Timer(timeInterval: desiredInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Common mode keeps session updates flowing while a touch is being
        // tracked on the key grid.
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
        pollingInterval = desiredInterval
    }

    private func refresh() {
        if let id = activeSessionID, let record = try? store.load(id) {
            if ![.launchingApp, .awaitingReturn].contains(record.state) {
                appLaunchFallbackTask?.cancel()
                appLaunchFallbackTask = nil
            }
            guard !expireIfStale(record) else { return }
            latchSessionTarget()
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
        // Adoption is how a session survives the keyboard being torn down for
        // the hand-off, so it must not also resurrect one nobody is waiting for.
        guard !expireIfStale(recent) else { return }
        activeSessionID = recent.sessionID
        // A recreated instance cannot compare its identifiers with ones the
        // previous instance stored, so the field the user has returned to
        // becomes the session's insertion target.
        sessionTargetDocumentID = currentDocumentID
        handle(recent)
    }

    /// Retires a session that is waiting for something no longer coming, and
    /// hands the bar back to the user. Reports whether it did, so callers stop
    /// rendering a record they have just made terminal.
    private func expireIfStale(_ record: SessionRecord) -> Bool {
        guard SessionExpiryPolicy.expireIfStale(record, in: store) != nil else { return false }
        if activeSessionID == record.sessionID {
            activeSessionID = nil
            sessionTargetDocumentID = nil
        }
        appLaunchFallbackTask?.cancel()
        appLaunchFallbackTask = nil
        render(nil)
        return true
    }

    /// iOS can withhold the document identifier while the keyboard is loading,
    /// and a session adopted in that window kept a nil target for its whole
    /// life — which silently disabled the wrong-field guard rather than
    /// tightening it. Latch the first identifier that becomes known instead,
    /// and never a later one, so the target still names one field.
    private func latchSessionTarget() {
        guard sessionTargetDocumentID == nil, let current = currentDocumentID else { return }
        sessionTargetDocumentID = current
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

    /// A strip update, and only a strip update.
    ///
    /// This runs on every keystroke, and it used to go through the full
    /// ``render(_:)`` — rebuilding the entire dictation bar model from the
    /// session record, the preference state and the transcript, re-deriving the
    /// bar's layout and height, and re-running the preference controls — to
    /// change three words in a row of chips. The bar's own `apply` bails on an
    /// unchanged model, but everything upstream of that comparison had already
    /// been paid for.
    ///
    /// The fast path is only taken when the bar is genuinely showing the strip.
    /// A recording or a waiting transcript owns the bar, and its candidates are
    /// empty by construction — those go through the full render, where they
    /// belong.
    private func renderStrip(_ strip: TypingStrip) {
        // An empty strip means the bar goes back to its controls, which is a
        // change of body rather than a change of chips — that belongs to the
        // full render, which owns the crossfade between the two.
        guard barLayout == .strip,
              !strip.candidates.isEmpty,
              lastRecord == nil || lastRecord?.state == .idle
        else {
            render(lastRecord)
            return
        }
        // The bar may still be showing its controls, in which case arriving at
        // the strip is a change of body and the full render owns the crossfade.
        if !dictationBar.updateCandidates(strip.candidates) { render(lastRecord) }
    }

    private func render(_ record: SessionRecord?) {
        lastRecord = record
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
                canUndo: lastInsertedText != nil,
                candidates: typing.strip.candidates,
                prefersQuickDictation: record?.prefersQuickDictation == true,
                processingLocation: record?.processingLocation
            )
        )

        // An idle keyboard needs no meter and no subtitle, and the height they
        // would occupy is better spent on the keys — the idle bar is a one-row
        // typing strip, shorter than the collapsed status bar it replaces.
        if model.isExpanded != isBarExpanded || model.layout != barLayout {
            isBarExpanded = model.isExpanded
            barLayout = model.layout
            applyLayoutMetrics(animated: hasRendered)
        }
        updateElapsedTime(for: state)
        if state == .recording {
            dictationBar.push(meterLevel: record?.meterLevel ?? 0)
        }
        dictationBar.apply(model, animated: hasRendered)
        announceStateChange(to: state, saying: model.announcement)
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
    ///
    /// Only genuine transitions, and only the ones the model marked worth
    /// interrupting for. Polling re-renders the same state up to four times a
    /// second, and announcing the timer or the meter alongside it would make
    /// VoiceOver unusable during a dictation.
    private func announceStateChange(to state: SessionState, saying announcement: String?) {
        guard state != lastRenderedState else { return }
        lastRenderedState = state
        guard announcesStateChanges, hasFullAccess else { return }
        if let announcement {
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
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
        keyboardStack = stack
        stack.axis = .vertical
        stack.spacing = Self.chromeSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Key previews for the top row draw above the grid's own bounds.
        stack.clipsToBounds = false
        view.clipsToBounds = false
        view.addSubview(stack)

        let barMetrics = DictationBarMetrics.resolved(
            for: traitCollection,
            preference: heightPreference
        )
        let barHeight = dictationBar.heightAnchor.constraint(
            equalToConstant: barMetrics.height(for: .strip, expanded: false)
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
        let metrics = KeyboardMetrics.resolved(
            for: traitCollection,
            preference: heightPreference
        )
        let barMetrics = DictationBarMetrics.resolved(
            for: traitCollection,
            preference: heightPreference
        )
        keyGrid.metrics = metrics
        dictationBar.metrics = barMetrics

        let barHeight = barMetrics.height(for: barLayout, expanded: isBarExpanded)
        barHeightConstraint?.constant = barHeight
        gridHeightConstraint?.constant = metrics.gridHeight
        emojiPanelHeightConstraint?.constant = metrics.gridHeight
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
        // Passwords, one-time codes and PINs switch the whole subsystem off —
        // not just the strip. A hidden strip over a live spell checker would
        // still be running the user's password through a dictionary.
        typing.documentChanged(policy: TypingFieldPolicy.resolve(for: proxy))
        keyGrid.showsGlobeKey = needsInputModeSwitchKey
        let returnKeyType = proxy.returnKeyType ?? .default
        keyGrid.returnKeyTitle = Self.returnKeyTitle(for: returnKeyType)
        keyGrid.returnKeyIsProminent = returnKeyType != .default
        let keyboardType = proxy.keyboardType ?? .default
        keyGrid.punctuation = Self.punctuation(for: keyboardType)
        keyGrid.keyboardType = keyboardType
        // The plane belongs to the field, not to wherever the last one left it.
        // A phone-number field has to arrive on its keypad, and it has nowhere
        // else to go once it is there.
        keyGrid.plane = Self.initialPlane(for: keyboardType)
        updateReturnKeyEnablement()
        applyTheme()
    }

    /// Dims Return in the fields that asked for it.
    ///
    /// `enablesReturnKeyAutomatically` is a field saying "there is nothing to
    /// send until something has been typed", and the system keyboard answers it
    /// by greying the key out. Ignoring it meant a Send button that looked live
    /// over an empty message and fired on an empty message.
    private func updateReturnKeyEnablement(for snapshot: DocumentSnapshot? = nil) {
        guard textDocumentProxy.enablesReturnKeyAutomatically == true else {
            keyGrid.returnKeyIsEnabled = true
            return
        }
        // Read fresh when no event snapshot was handed in: this is reached from
        // `viewWillAppear`, which is not inside an event.
        let resolved = snapshot ?? readDocument()
        // The proxy answers with nothing while the keyboard is loading, which is
        // not the same as an empty field. Dimming Return on that would grey out
        // the Send button over a message the user has already written.
        guard resolved.before != nil || resolved.after != nil else {
            keyGrid.returnKeyIsEnabled = true
            return
        }
        keyGrid.returnKeyIsEnabled = !(resolved.before ?? "").isEmpty
            || !(resolved.after ?? "").isEmpty
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

    /// Email and web fields put their most-used separator on the bottom row,
    /// the way the system keyboard does — and every other field gets none, also
    /// the way the system keyboard does. A plain iPhone QWERTY has `123`, the
    /// globe, space and return on that row and nothing else; the comma and full
    /// stop this used to add were two keys the spacebar could have been.
    private static func punctuation(for type: UIKeyboardType) -> KeyLayout.BottomRowPunctuation? {
        switch type {
        case .emailAddress: KeyLayout.BottomRowPunctuation(leading: "@", trailing: ".")
        case .URL, .webSearch: KeyLayout.BottomRowPunctuation(leading: "/", trailing: ".")
        // The two characters a Twitter-style field is for. iOS puts both on the
        // bottom row here, and the pair used to be unreachable because the
        // trailing slot was hardcoded to a full stop.
        case .twitter: KeyLayout.BottomRowPunctuation(leading: "@", trailing: "#")
        default: nil
        }
    }

    private static func initialPlane(for type: UIKeyboardType) -> KeyPlane {
        switch type {
        // A real keypad, not the symbols plane wearing a hat. A verification
        // code or a phone number typed against `-/:;()$&@"` is a keyboard that
        // has not noticed where it is.
        case .numberPad, .asciiCapableNumberPad: .numberPad
        case .phonePad: .phonePad
        case .decimalPad: .decimalPad
        // Punctuation is the point of this one, so it keeps the full plane.
        case .numbersAndPunctuation: .numbers
        default: .letters
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
    private func updateAutomaticShift(for snapshot: DocumentSnapshot? = nil) {
        // `nil` means leave the shift key alone, which is the answer whenever
        // the host declined to say what the document contains. See
        // ``AutomaticShift``.
        guard let state = AutomaticShift.state(
            documentBefore: (snapshot ?? document).before,
            autocapitalization: textDocumentProxy.autocapitalizationType ?? .sentences,
            current: keyGrid.shiftState
        ) else { return }
        keyGrid.shiftState = state
    }
}

extension KeyboardViewController: EmojiPanelViewDelegate {
    func emojiPanel(_ panel: EmojiPanelView, didChoose glyph: String) {
        documentEvent {
            textDocumentProxy.insertText(glyph)
            // An emoji ends a word as surely as a space does, and it is never
            // something to autocorrect.
            typing.resetComposition(origin: .suggestion, document: refreshDocument())
            releaseUndoIfDetached()
        }
    }

    func emojiPanelDidRequestDelete(_ panel: EmojiPanelView) {
        documentEvent {
            deleteBackward()
            releaseUndoIfDetached()
        }
    }

    func emojiPanelDidRequestReturn(_ panel: EmojiPanelView) {
        documentEvent {
            commitComposition(followedBy: "\n")
            releaseUndoIfDetached()
        }
    }

    func emojiPanelDidRequestSpace(_ panel: EmojiPanelView) {
        documentEvent { insertSpace() }
    }

    func emojiPanelDidRequestLetters(_ panel: EmojiPanelView) {
        showEmojiPanel(false)
        keyGrid.plane = .letters
    }
}

extension KeyboardViewController: KeyGridViewDelegate {
    /// A held Delete stops at the start of a line. Continuing past it takes a
    /// fresh press, which is what keeps one long hold from swallowing the
    /// paragraph above the one being edited.
    func keyGridShouldContinueDeleting(_ grid: KeyGridView) -> Bool {
        guard let before = readDocument().before else { return true }
        return !before.isEmpty && !before.hasSuffix("\n")
    }
}

extension KeyboardViewController: DictationBarViewDelegate {
    func dictationBar(_ bar: DictationBarView, didTrigger action: DictationAction) {
        perform(action)
    }

    func dictationBarDidChangePreferences(_ bar: DictationBarView) {
        refresh()
    }

    /// A tapped chip. Each kind means something different to the document, and
    /// the literal means nothing to it at all.
    func dictationBar(_ bar: DictationBarView, didChoose candidate: TypingCandidate) {
        guard !isPerformingInsertion else { return }
        documentEvent { apply(candidate) }
    }

    private func apply(_ candidate: TypingCandidate) {
        switch candidate.kind {
        case .literal:
            // The user's own spelling, asserted. Nothing is rewritten — the
            // point is that what they typed stays exactly as typed — but it
            // stops being corrected, and the keyboard learns it.
            typing.assert(candidate.text)
            render(lastRecord)
        case .revert:
            // The correction has already gone into the document. Taking it back
            // is the same operation Delete performs, and it asserts the word so
            // the keyboard does not simply do it again on the next sentence.
            revertPendingCorrection()
        case .completion, .correction:
            let typed = typing.composer.text
            for _ in 0..<typed.count { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(candidate.text + " ")
            typing.noteCompletedWord(candidate.text)
            typing.resetComposition(origin: .suggestion, document: refreshDocument())
        case .prediction:
            textDocumentProxy.insertText(candidate.text + " ")
            typing.resetComposition(origin: .suggestion, document: refreshDocument())
        case .swipeAlternate:
            // The swiped word is already in the document with the space that
            // followed it, so the replacement covers both and puts a space
            // back. Deleting only the composition — which is empty by now,
            // because the cursor sits past that space — is what left the
            // rejected word in place with the alternate after it.
            // Checked against the document, not against remembered state: the
            // document wins here as it does everywhere else in this
            // subsystem, and a replacement that cannot see the word it is
            // replacing must not delete four characters on faith.
            guard let swiped = typing.pendingSwipeWord,
                  SwipeAlternates.isArmed(word: swiped, documentBefore: document.before)
            else { break }
            let alternates = SwipeAlternates.alternates(
                after: candidate.text,
                replacing: swiped,
                from: typing.pendingSwipeAlternates
            )
            for _ in 0..<SwipeAlternates.deletionCount(replacing: swiped) {
                textDocumentProxy.deleteBackward()
            }
            textDocumentProxy.insertText(candidate.text + " ")
            refreshDocument()
            // Re-armed on the new word, so a second thought is another tap
            // rather than a retype.
            typing.noteSwipeWord(candidate.text, alternates: alternates)
        case .emoji:
            // The emoji stands in for the word, exactly as the system keyboard
            // does it: "lol" becomes 😂 rather than "lol 😂".
            let typed = typing.composer.text
            for _ in 0..<typed.count { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(candidate.text + " ")
            // Deliberately not learned. `noteCompletedWord` teaches the
            // keyboard vocabulary, and an emoji is not a word it should start
            // completing letters into.
            typing.resetComposition(origin: .suggestion, document: refreshDocument())
        }
        lastSpaceInsertedAt = nil
        releaseUndoIfDetached()
        updateAutomaticShift()
    }
}
