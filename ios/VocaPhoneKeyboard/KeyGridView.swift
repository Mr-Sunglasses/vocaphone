import UIKit

enum KeyboardOutput {
    case text(String)
    case space
    case newline
    case deleteBackward
    case deleteWord
    case moveCursor(Int)
    /// A traced word and the alternates that lost to it, for the strip.
    case swipeWord(String, alternates: [String])
    /// Hold the plane key to reach the emoji panel.
    ///
    /// A dedicated emoji key does not fit: the bottom row balances on ten
    /// columns, and a fourth function key beside the plane switch, the globe and
    /// the punctuation pair leaves the spacebar about half a key wide. iOS has
    /// the same problem and answers it by not putting a comma and full stop on
    /// that row at all — which this keyboard does, and people use them.
    case emojiPanel
    /// Carries the globe key itself so the keyboard picker can anchor to it.
    case nextInputMode(UIView, UIEvent?)
}

enum CursorTrackpad {
    static let pointsPerCharacter: CGFloat = 10

    static func step(forHorizontalTranslation translation: CGFloat) -> Int {
        Int(translation / pointsPerCharacter)
    }
}

@MainActor
protocol KeyGridViewDelegate: AnyObject {
    func keyGrid(_ grid: KeyGridView, didProduce output: KeyboardOutput)
    func keyGridDidChangeShift(_ grid: KeyGridView)
    /// Whether a held Delete may keep going. Only the controller can see the
    /// document, and the system keyboard stops at the start of a line rather
    /// than eating the paragraph behind it.
    func keyGridShouldContinueDeleting(_ grid: KeyGridView) -> Bool
}

/// The typing area. Owns hit testing, so keys can be slid between and their
/// touch targets can spill into the gutters — both impossible with one control
/// per key reacting to `touchUpInside`.
final class KeyGridView: UIView {
    weak var delegate: (any KeyGridViewDelegate)?
    private let feedback: any KeyboardFeedbackProviding

    var metrics: KeyboardMetrics {
        didSet { if metrics != oldValue { rebuild() } }
    }

    var palette: KeyboardPalette {
        didSet { if palette != oldValue { rebuild() } }
    }

    var plane: KeyPlane = .letters {
        didSet { if plane != oldValue { activatePlane() } }
    }

    var showsGlobeKey = true {
        didSet { if showsGlobeKey != oldValue { rebuild() } }
    }

    var returnKeyIsProminent = false {
        didSet { if returnKeyIsProminent != oldValue { rebuild() } }
    }

    var returnKeyTitle = "return" {
        didSet { if returnKeyTitle != oldValue { updateKeys() } }
    }

    /// The punctuation pair on the letters plane, or `nil` for none — which is
    /// the plain QWERTY case, matching the system keyboard.
    var leadingPunctuation: String? {
        didSet { if leadingPunctuation != oldValue { rebuild() } }
    }

    /// The word list the swipe recogniser ranks against. Set by the controller
    /// once the list has loaded; with no list there is no swipe, which is the
    /// correct failure — a recogniser with nothing to recognise against would
    /// commit nonsense.
    var swipeWordList: TypingWordList?

    /// The field's own keyboard type, which decides whether a long press on `.`
    /// offers domains.
    var keyboardType: UIKeyboardType = .default {
        didSet { if keyboardType != oldValue { rebuild() } }
    }

    var shiftState: ShiftState = .on {
        didSet {
            guard shiftState != oldValue else { return }
            updateKeys()
            delegate?.keyGridDidChangeShift(self)
        }
    }

    private(set) var rows: [KeyRow] = []
    private(set) var keyViews: [KeyView] = []
    /// Switching to digits and back is frequent, and rebuilding thirty-odd key
    /// views each time means re-resolving fonts and symbol images. Built planes
    /// are kept and simply hidden; only a metrics or palette change discards them.
    private var planeCache: [KeyPlane: (rows: [KeyRow], views: [KeyView])] = [:]
    private var previewPool: [KeyPreviewView] = []
    /// The fading stroke drawn under the finger while a swipe is in flight.
    /// Created once and kept above the keys; it never takes a touch.
    private lazy var swipeTrail = SwipeTrailView(color: palette.swipeTrail)
    /// One popover, reused. Only one finger can be holding a letter at a time in
    /// any interaction that makes sense, and allocating a view per long press
    /// would churn labels the pool exists to avoid.
    private var alternativesView: KeyAlternativesView?
    /// Rebuilt by layout from the same frames that are rendered. Touches never
    /// scan UIKit subviews directly, so a gutter boundary has one stable owner.
    private var hitMap = KeyHitMap(targets: [])
    private var tracked: [TrackedTouch] = []
    /// The plane key's hold-for-emoji gesture. Owned by the grid rather than by
    /// a `TrackedTouch`, because the plane switch it rides on releases those.
    private var planeHoldTimer: Timer?
    private weak var planeHoldTouch: UITouch?
    private var planeHoldOrigin: KeyPlane?
    private var planeHoldPoint: CGPoint?
    private var deleteTimer: Timer?
    private var spaceTrackpadTimer: Timer?
    private var deleteRepeatCount = 0
    private var lastShiftTapAt: Date?

    private final class TrackedTouch: @unchecked Sendable {
        let touch: UITouch
        var key: KeyView
        /// Whether the finger may leave this key and type the one it lands on.
        /// Characters always may. So do Shift and the plane key, because iOS
        /// lets a press on either slide onto a letter or symbol, type it, and
        /// drop the modifier — one of the gestures people type by reflex.
        let allowsSlide: Bool
        /// Only a touch that began on a character may become a traced word. A
        /// slide off Shift travels just as far and must not be read as one.
        let allowsSwipe: Bool
        /// Set when this touch began on the plane key: the plane to return to
        /// once the slide has typed something. A plain tap leaves it nil, so
        /// tapping `123` stays on the numbers plane the way it should.
        let planeToRestore: KeyPlane?
        /// A slide that started on a modifier only commits while the finger is
        /// still over the key it landed on — sliding back to the modifier and
        /// lifting types nothing, as on iOS.
        var isModifierSlide: Bool { planeToRestore != nil || startedOnShift }
        private let startedOnShift: Bool
        var preview: KeyPreviewView?
        let initialPoint: CGPoint
        var lastCursorStep = 0
        var isCursorTracking = false
        /// Fires the accent popover if the finger is still on the key. Cancelled
        /// by movement, by lifting, and by anything that tears the grid down.
        var longPressTimer: Timer?
        var isChoosingAlternative = false
        /// Sampled points, once the finger has travelled far enough for this to
        /// be a swipe rather than a slide to correct a target.
        var swipePath: [CGPoint] = []
        var isSwiping = false

        init(
            touch: UITouch,
            key: KeyView,
            initialPoint: CGPoint,
            planeToRestore: KeyPlane? = nil
        ) {
            self.touch = touch
            self.key = key
            self.initialPoint = initialPoint
            self.planeToRestore = planeToRestore
            startedOnShift = key.spec.cap == .shift
            allowsSwipe = key.spec.cap.isCharacter
            allowsSlide = key.spec.cap.isCharacter || startedOnShift || planeToRestore != nil
        }
    }

    init(
        metrics: KeyboardMetrics,
        palette: KeyboardPalette,
        feedback: any KeyboardFeedbackProviding = KeyboardHaptics.shared
    ) {
        self.metrics = metrics
        self.palette = palette
        self.feedback = feedback
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        // Previews for the top row rise above the grid's own bounds.
        clipsToBounds = false
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: metrics.gridHeight)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // The trail is drawn in the grid's own coordinates, so it spans it.
        swipeTrail.frame = bounds
        let available = bounds.width - 2 * metrics.sideInset
        // Every row resolves against the width of one letter column from the
        // ten-key reference row, which is what keeps columns aligned vertically.
        let unit = (available - 9 * metrics.columnGap) / 10
        guard unit > 0 else {
            hitMap = KeyHitMap(targets: [])
            return
        }

        var keyIndex = 0
        var targets: [KeyHitMap.Target] = []
        targets.reserveCapacity(keyViews.count)
        var y: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            let widths = resolvedWidths(for: row, unit: unit, available: available)
            let span = widths.reduce(0, +)
                + CGFloat(max(widths.count - 1, 0)) * metrics.columnGap
            var x = row.alignment == .centered
                ? metrics.sideInset + (available - span) / 2
                : metrics.sideInset

            for (column, width) in widths.enumerated() {
                let key = keyViews[keyIndex]
                let slotFrame = CGRect(
                    x: x,
                    y: y,
                    width: width,
                    height: metrics.keyHeight
                )
                key.frame = visibleFrame(
                    for: slotFrame,
                    key: key,
                    row: row,
                    unit: unit
                )
                key.hitRect = hitRect(
                    for: slotFrame,
                    isLeading: column == 0,
                    isTrailing: column == widths.count - 1,
                    isTopRow: rowIndex == 0,
                    isBottomRow: rowIndex == rows.count - 1
                )
                // The slot, not `key.frame`: Shift and Delete render inset to
                // leave the native moat around them, and measuring from the
                // shrunken visual centre would hand their share of the gutter
                // to the neighbouring letter — losing the touch target the
                // inset was written to preserve.
                targets.append(
                    KeyHitMap.Target(
                        index: keyIndex,
                        frame: slotFrame,
                        hitRect: key.hitRect,
                        isCharacter: key.spec.cap.isCharacter
                    )
                )
                x += width + metrics.columnGap
                keyIndex += 1
            }
            y += metrics.keyHeight + metrics.rowGap
        }

        hitMap = KeyHitMap(targets: targets)
    }

    /// The native letters plane leaves a larger visual moat around Shift and
    /// Delete without sacrificing their touch targets. Keep the original slot
    /// for hit testing, and only inset the rendered key toward the outside.
    private func visibleFrame(
        for slotFrame: CGRect,
        key: KeyView,
        row: KeyRow,
        unit: CGFloat
    ) -> CGRect {
        guard row.keys.first?.cap == .shift else { return slotFrame }
        let nativeModifierWidth = unit + 12
        let inset = max(slotFrame.width - nativeModifierWidth, 0)
        switch key.spec.cap {
        case .shift:
            return CGRect(
                x: slotFrame.minX,
                y: slotFrame.minY,
                width: slotFrame.width - inset,
                height: slotFrame.height
            )
        case .delete:
            return CGRect(
                x: slotFrame.minX + inset,
                y: slotFrame.minY,
                width: slotFrame.width - inset,
                height: slotFrame.height
            )
        default:
            return slotFrame
        }
    }

    private func resolvedWidths(
        for row: KeyRow,
        unit: CGFloat,
        available: CGFloat
    ) -> [CGFloat] {
        var widths = [CGFloat](repeating: 0, count: row.keys.count)
        var fillIndices: [Int] = []
        var fixedTotal: CGFloat = 0

        for (index, key) in row.keys.enumerated() {
            switch key.width {
            case .unit:
                widths[index] = unit
                fixedTotal += unit
            case let .multiple(columns):
                let width = columns * unit + (columns - 1) * metrics.columnGap
                widths[index] = width
                fixedTotal += width
            case .fill:
                fillIndices.append(index)
            }
        }

        guard !fillIndices.isEmpty else { return widths }
        let gaps = CGFloat(max(row.keys.count - 1, 0)) * metrics.columnGap
        let share = max(unit, (available - fixedTotal - gaps) / CGFloat(fillIndices.count))
        for index in fillIndices { widths[index] = share }
        return widths
    }

    /// Keys claim the surrounding gutter, and edge keys claim everything out to
    /// the boundary. A near miss should still type the intended character.
    private func hitRect(
        for frame: CGRect,
        isLeading: Bool,
        isTrailing: Bool,
        isTopRow: Bool,
        isBottomRow: Bool
    ) -> CGRect {
        var rect = frame.insetBy(dx: -metrics.columnGap / 2, dy: -metrics.rowGap / 2)
        if isLeading {
            rect = CGRect(x: 0, y: rect.minY, width: rect.maxX, height: rect.height)
        }
        if isTrailing {
            rect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: bounds.width - rect.minX,
                height: rect.height
            )
        }
        if isTopRow {
            rect = CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.maxY)
        }
        if isBottomRow {
            rect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: bounds.height - rect.minY
            )
        }
        return rect
    }

    // MARK: - Building

    /// Discards every cached plane. Only geometry or colour changes need this;
    /// a plane switch goes through `activatePlane`.
    private func rebuild() {
        hitMap = KeyHitMap(targets: [])
        endDeleteRepeat()
        cancelPlaneHold()
        releaseTouches()
        for (_, plane) in planeCache {
            plane.views.forEach { $0.removeFromSuperview() }
        }
        planeCache.removeAll()
        previewPool.forEach { $0.removeFromSuperview() }
        previewPool.removeAll()
        alternativesView?.removeFromSuperview()
        alternativesView = nil
        keyViews.removeAll()
        rows.removeAll()
        activatePlane()
    }

    private func activatePlane() {
        // Cleared here and rebuilt before this method returns: never let a
        // touch resolve old target indices against the new plane's views.
        hitMap = KeyHitMap(targets: [])
        endDeleteRepeat()
        releaseTouches()
        keyViews.forEach { $0.isHidden = true }

        let entry: (rows: [KeyRow], views: [KeyView])
        if let cached = planeCache[plane] {
            entry = cached
        } else {
            let built = KeyLayout.rows(
                for: plane,
                includesGlobe: showsGlobeKey,
                returnIsProminent: returnKeyIsProminent,
                leadingPunctuation: leadingPunctuation
            )
            var views: [KeyView] = []
            views.reserveCapacity(built.reduce(0) { $0 + $1.keys.count })
            for row in built {
                for spec in row.keys {
                    let key = KeyView(spec: spec, metrics: metrics, palette: palette)
                    key.alternativesKeyboardType = keyboardType
                    key.accessibilityDelegate = self
                    addSubview(key)
                    views.append(key)
                }
            }
            entry = (built, views)
            planeCache[plane] = entry
        }

        rows = entry.rows
        keyViews = entry.views
        keyViews.forEach { $0.isHidden = false }
        // Re-added rather than merely kept: `addSubview` moves it back above the
        // keys this plane has just installed. Previews and the accent popover
        // still come out on top, because both bring themselves to the front.
        swipeTrail.color = palette.swipeTrail
        addSubview(swipeTrail)
        updateKeys()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        // `setNeedsLayout()` alone defers the new geometry to the next layout
        // pass, and `touchesBegan` walks an unordered set: a second finger
        // landing in the same event as a plane switch would resolve against an
        // empty map and be silently dropped. Two-thumb typists hit that.
        layoutIfNeeded()
    }

    /// Abandons everything in flight — held keys, delete repeat, an open accent
    /// popover. The keyboard calls this when it leaves the screen, because iOS
    /// does not always deliver `touchesCancelled` for a keyboard that is being
    /// dismissed, and a popover left behind reappears over the next field.
    func endActiveInteractions() {
        endDeleteRepeat()
        cancelPlaneHold()
        releaseTouches()
    }

    private func releaseTouches() {
        spaceTrackpadTimer?.invalidate()
        spaceTrackpadTimer = nil
        swipeTrail.cancel()
        for item in tracked {
            item.longPressTimer?.invalidate()
            item.longPressTimer = nil
            item.key.isHighlighted = false
            recycle(item.preview)
            item.preview = nil
        }
        tracked.removeAll()
        dismissAlternatives()
    }

    private func updateKeys() {
        for key in keyViews {
            key.update(
                metrics: metrics,
                palette: palette,
                shift: shiftState,
                returnTitle: returnKeyTitle
            )
        }
    }

    // MARK: - Touch tracking

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            guard let key = key(at: point, characterOnly: false)
            else { continue }
            let item = TrackedTouch(touch: touch, key: key, initialPoint: point)
            tracked.append(item)
            key.isHighlighted = true
            // The click belongs to the press, not to the commit: the system
            // keyboard sounds a key as the finger lands, and every key here
            // does the same so the rhythm never depends on which key it was.
            feedback.keyPressed()
            showPreview(for: item)
            if key.spec.cap == .space { scheduleSpaceTrackpad(for: item) }
            scheduleAlternatives(for: item)
            if case .plane = key.spec.cap {
                beginPlaneHold(at: point)
                planeHoldTouch = touch
            }
            if key.spec.cap.actsOnTouchDown {
                let planeBefore = plane
                performTouchDownAction(for: key, event: event)
                // Switching planes rebuilds the grid and releases every touch,
                // this one included. Re-register it against the plane the
                // finger is now looking at, so it can slide onto a symbol and
                // type it on lift the way the system keyboard does.
                if case .plane = key.spec.cap, plane != planeBefore,
                   let landed = self.key(at: point, characterOnly: false)
                {
                    let slide = TrackedTouch(
                        touch: touch,
                        key: landed,
                        initialPoint: point,
                        planeToRestore: planeBefore
                    )
                    tracked.append(slide)
                    landed.isHighlighted = true
                }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if planeHoldTouch === touch, let origin = planeHoldPoint {
                let point = touch.location(in: self)
                // Sliding off the plane key is a change of mind about the key,
                // not a hold — the same 12pt slack the accent popover allows.
                if hypot(point.x - origin.x, point.y - origin.y) > 12 { cancelPlaneHold() }
            }
            guard let item = tracked.first(where: { $0.touch === touch }) else { continue }
            let point = touch.location(in: self)

            if item.isChoosingAlternative {
                handleAlternativeMovement(item, point: point)
                continue
            }

            if item.key.spec.cap == .space {
                handleSpaceMovement(item, point: point)
                continue
            }

            // Sliding to a neighbour is a correction, not a hold, so it retires
            // the pending popover rather than firing it under a different key.
            if item.longPressTimer != nil,
               hypot(point.x - item.initialPoint.x, point.y - item.initialPoint.y) > 12
            {
                item.longPressTimer?.invalidate()
                item.longPressTimer = nil
            }

            guard item.allowsSlide else {
                // Function keys stay bound to their own touch but disengage when
                // the finger wanders off, so a drag away cancels instead of
                // firing something the user no longer intends.
                let isInside = item.key.hitRect.contains(point)
                guard item.key.isHighlighted != isInside else { continue }
                item.key.isHighlighted = isInside
                if item.key.spec.cap == .delete {
                    isInside ? startDeleteTimer() : endDeleteRepeat()
                }
                continue
            }

            if swipeTypingIsAvailable, item.allowsSwipe {
                let travelled = hypot(
                    point.x - item.initialPoint.x,
                    point.y - item.initialPoint.y
                )
                if !item.isSwiping, travelled > SwipeRecognizer.activationDistance {
                    // Only now is this a swipe. Below the threshold it is the
                    // slide-to-correct-a-target gesture the keyboard already
                    // had, and stealing that would break ordinary typing.
                    item.isSwiping = true
                    item.swipePath = [item.initialPoint]
                    recycle(item.preview)
                    item.preview = nil
                    // The trail starts at the key the finger came from, not at
                    // the point where the threshold was crossed: the first
                    // letter is part of the word, and a stroke that began in
                    // mid-air would look like a dropped frame.
                    swipeTrail.begin(at: item.initialPoint)
                    bringSubviewToFront(swipeTrail)
                    feedback.swipeBegan()
                }
                if item.isSwiping {
                    item.swipePath.append(point)
                    swipeTrail.extend(to: point)
                    if let key = key(at: point, characterOnly: true), key !== item.key {
                        item.key.isHighlighted = false
                        item.key = key
                        key.isHighlighted = true
                    }
                    continue
                }
            }

            guard let key = key(at: point, characterOnly: true), key !== item.key else { continue }
            item.key.isHighlighted = false
            item.key = key
            key.isHighlighted = true
            showPreview(for: item)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, commit: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, commit: false)
    }

    private func finish(_ touches: Set<UITouch>, commit: Bool) {
        // Applied after the loop: restoring the plane rebuilds the grid and
        // releases every tracked touch, which would strand the other fingers
        // of a multi-touch batch before they have been read.
        var planeToRestore: KeyPlane?
        for touch in touches {
            if planeHoldTouch === touch { cancelPlaneHold() }
            guard let index = tracked.firstIndex(where: { $0.touch === touch }) else { continue }
            let item = tracked.remove(at: index)
            if item.key.spec.cap == .space {
                spaceTrackpadTimer?.invalidate()
                spaceTrackpadTimer = nil
            }
            item.longPressTimer?.invalidate()
            item.longPressTimer = nil
            var shouldCommit = commit && item.key.isHighlighted && !item.isCursorTracking
            // A slide that began on Shift or the plane key tracks characters
            // only, so sliding back onto the modifier leaves `item.key` on the
            // letter it passed over. Lifting there must type nothing.
            if item.isModifierSlide,
               !item.key.hitRect.contains(touch.location(in: self))
            {
                shouldCommit = false
            }
            item.key.isHighlighted = false
            recycle(item.preview)
            item.preview = nil
            if item.key.spec.cap == .delete { endDeleteRepeat() }
            if item.isSwiping {
                item.key.isHighlighted = false
                let path = item.swipePath
                item.swipePath = []
                item.isSwiping = false
                // A committed swipe lets its trail fade out under the word that
                // just appeared; a cancelled one takes the trail with it.
                if commit {
                    swipeTrail.end()
                    commitSwipe(path)
                } else {
                    swipeTrail.cancel()
                }
                continue
            }
            if item.isChoosingAlternative {
                let choice = alternativesView?.highlightedOption
                dismissAlternatives()
                guard commit, let choice else { continue }
                feedback.textCommitted()
                delegate?.keyGrid(self, didProduce: .text(choice))
                if shiftState == .on { shiftState = .off }
                continue
            }
            let didCommit = completeKeyInteraction(
                item.key,
                shouldCommit: shouldCommit && !item.key.spec.cap.actsOnTouchDown
            )
            // Typing a symbol this way returns to the plane the finger came
            // from; lifting on the plane key itself commits nothing and stays.
            if didCommit, let origin = item.planeToRestore { planeToRestore = origin }
        }
        if let planeToRestore { plane = planeToRestore }
    }

    /// The single completion boundary for ordinary taps and slide correction.
    /// Keeping the commit decision here makes cancellation testable without
    /// constructing UIKit-owned `UITouch` instances.
    @discardableResult
    func completeKeyInteraction(_ key: KeyView, shouldCommit: Bool) -> Bool {
        guard shouldCommit else { return false }
        switch key.spec.cap {
        case .character:
            guard let text = key.previewText else { return false }
            feedback.textCommitted()
            delegate?.keyGrid(self, didProduce: .text(text))
            // Also what ends a slide off Shift: one capital, then back to
            // lowercase. A locked Shift is a deliberate state and outranks it.
            if shiftState == .on { shiftState = .off }
            return true
        case .space:
            feedback.textCommitted()
            delegate?.keyGrid(self, didProduce: .space)
            return true
        case .newline:
            feedback.textCommitted()
            delegate?.keyGrid(self, didProduce: .newline)
            return true
        default:
            return false
        }
    }

    private func performTouchDownAction(for key: KeyView, event: UIEvent?) {
        feedback.keyActionCommitted()
        switch key.spec.cap {
        case .delete:
            delegate?.keyGrid(self, didProduce: .deleteBackward)
            startDeleteTimer()
        case .shift:
            toggleShift()
        case let .plane(next):
            plane = next
        case .globe:
            delegate?.keyGrid(self, didProduce: .nextInputMode(key, event))
        default:
            break
        }
    }

    private func scheduleSpaceTrackpad(for item: TrackedTouch) {
        guard !UIAccessibility.isVoiceOverRunning else { return }
        spaceTrackpadTimer?.invalidate()
        spaceTrackpadTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: false) {
            [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let item,
                      self.tracked.contains(where: { $0 === item }),
                      item.key.isHighlighted
                else { return }
                item.isCursorTracking = true
                item.lastCursorStep = 0
                self.feedback.selectionChanged()
                UIAccessibility.post(notification: .announcement, argument: "Cursor control")
            }
        }
    }

    private func handleSpaceMovement(_ item: TrackedTouch, point: CGPoint) {
        guard item.isCursorTracking else {
            let distance = hypot(point.x - item.initialPoint.x, point.y - item.initialPoint.y)
            if distance > 14 {
                spaceTrackpadTimer?.invalidate()
                spaceTrackpadTimer = nil
            }
            item.key.isHighlighted = item.key.hitRect.contains(point)
            return
        }

        item.key.isHighlighted = true
        let step = CursorTrackpad.step(
            forHorizontalTranslation: point.x - item.initialPoint.x
        )
        let delta = step - item.lastCursorStep
        guard delta != 0 else { return }
        item.lastCursorStep = step
        delegate?.keyGrid(self, didProduce: .moveCursor(delta))
    }

    // MARK: - Swipe

    private var swipeTypingIsAvailable: Bool {
        KeyboardPreferences.swipeTypingEnabled
            && swipeWordList?.isEmpty == false
            && !UIAccessibility.isVoiceOverRunning
    }

    /// The letter centres of the current plane, which is what the recogniser
    /// scores against. Rebuilt per swipe rather than cached: it is thirty
    /// lookups, and a cache would go stale on every layout change.
    private func swipeKeys() -> [SwipeRecognizer.Key] {
        keyViews.compactMap { key in
            guard case let .character(text) = key.spec.cap,
                  let character = text.lowercased().first,
                  character.isLetter
            else { return nil }
            return SwipeRecognizer.Key(character: character, centre: CGPoint(
                x: key.frame.midX,
                y: key.frame.midY
            ))
        }
    }

    private func commitSwipe(_ path: [CGPoint]) {
        guard let wordList = swipeWordList else { return }
        let recognizer = SwipeRecognizer(keys: swipeKeys())
        guard recognizer.isUsable else { return }
        let trace = recognizer.trace(path)
        let candidates = recognizer.candidates(for: trace, in: wordList)
        guard let best = candidates.first else { return }
        feedback.swipeCommitted()
        delegate?.keyGrid(
            self,
            didProduce: .swipeWord(best, alternates: Array(candidates.dropFirst()))
        )
        if shiftState == .on { shiftState = .off }
    }

    // MARK: - Accent alternatives

    /// Arms the long press, when the key has something to offer.
    ///
    /// VoiceOver is excluded outright rather than adapted: a screen reader's
    /// focus model has no finger to hold, and the alternatives are reachable
    /// through the key's accessibility custom actions instead — see
    /// ``KeyView/refresh()``.
    /// Holding the plane key opens the emoji panel.
    ///
    /// The hold cannot hang off the `TrackedTouch` the way the accent popover
    /// does. The plane key acts on touch-down, and switching planes rebuilds
    /// the grid and releases every tracked touch — which invalidated this very
    /// timer before it could ever fire, leaving the gesture unreachable. The
    /// grid owns it instead, and remembers the plane the hold started from so
    /// reaching the panel does not also leave a plane switch behind it.
    /// Arms the hold, remembering the plane it started from. Split from touch
    /// handling — and from the touch's own identity — so the gesture the plane
    /// switch used to swallow can be tested without a UIKit-owned `UITouch`.
    func beginPlaneHold(at point: CGPoint) {
        guard !UIAccessibility.isVoiceOverRunning else { return }
        cancelPlaneHold()
        planeHoldOrigin = plane
        planeHoldPoint = point
        planeHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.completePlaneHold() }
        }
    }

    func completePlaneHold() {
        guard let origin = planeHoldOrigin else { return }
        cancelPlaneHold()
        // The tap already switched planes as the finger landed. A hold means
        // the panel was wanted instead, so the switch is undone rather than
        // left waiting underneath it.
        plane = origin
        feedback.selectionChanged()
        delegate?.keyGrid(self, didProduce: .emojiPanel)
    }

    private func cancelPlaneHold() {
        planeHoldTimer?.invalidate()
        planeHoldTimer = nil
        planeHoldTouch = nil
        planeHoldOrigin = nil
        planeHoldPoint = nil
    }

    private func scheduleAlternatives(for item: TrackedTouch) {
        guard !UIAccessibility.isVoiceOverRunning,
              metrics.showsPreview,
              case let .character(base) = item.key.spec.cap,
              KeyAlternatives.hasOptions(for: base, keyboardType: keyboardType)
        else { return }
        item.longPressTimer?.invalidate()
        item.longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) {
            [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let item,
                      self.tracked.contains(where: { $0 === item }),
                      item.key.isHighlighted
                else { return }
                self.presentAlternatives(for: item)
            }
        }
    }

    private func presentAlternatives(for item: TrackedTouch) {
        guard case let .character(base) = item.key.spec.cap else { return }
        let options = KeyAlternatives.options(
            for: base,
            shift: shiftState,
            keyboardType: keyboardType
        )
        guard options.count > 1 else { return }

        // The magnified preview and the popover say the same thing; keeping both
        // would stack two surfaces over one key.
        recycle(item.preview)
        item.preview = nil

        let popover = alternativesView ?? {
            let created = KeyAlternativesView(palette: palette, metrics: metrics)
            addSubview(created)
            alternativesView = created
            return created
        }()
        popover.isHidden = false
        popover.show(options, palette: palette, metrics: metrics)

        let size = popover.size(for: options)
        let frame = item.key.frame
        // Anchored above the key and nudged inside the grid, so a popover on the
        // "a" or the "l" never hangs off the edge.
        let x = min(max(frame.midX - size.width / 2, 2), max(bounds.width - size.width - 2, 2))
        popover.frame = CGRect(x: x, y: frame.minY - size.height - 6, width: size.width, height: size.height)
        bringSubviewToFront(popover)

        item.isChoosingAlternative = true
        item.longPressTimer = nil
        feedback.selectionChanged()
    }

    private func handleAlternativeMovement(_ item: TrackedTouch, point: CGPoint) {
        guard let popover = alternativesView else { return }
        let local = convert(point, to: popover)
        if popover.highlightOption(atX: local.x) {
            feedback.selectionChanged()
        }
    }

    private func dismissAlternatives() {
        alternativesView?.isHidden = true
        for item in tracked { item.isChoosingAlternative = false }
    }

    private func toggleShift() {
        let now = Date()
        let isDoubleTap = lastShiftTapAt.map { now.timeIntervalSince($0) < 0.35 } ?? false
        lastShiftTapAt = now
        shiftState = isDoubleTap ? .locked : (shiftState == .off ? .on : .off)
    }

    func key(at point: CGPoint, characterOnly: Bool) -> KeyView? {
        guard let index = hitMap.targetIndex(at: point, characterOnly: characterOnly),
              keyViews.indices.contains(index)
        else { return nil }
        return keyViews[index]
    }

    // MARK: - Delete repeat

    /// The first repeat waits; the ones after it accelerate.
    ///
    /// The old behaviour was a flat 0.08 s from the first repeat, which is
    /// faster than the system keyboard at the start — so a hold meant to remove
    /// two letters removed five — and slower than it once a long deletion is
    /// genuinely under way.
    ///
    /// The floor is the part that has to stay honest. iOS settles at roughly
    /// ten characters a second and holds there; ramping to 0.045 s was more
    /// than twice that, which is how a hold meant to clear a word clears the
    /// sentence before the finger lifts.
    private static let deleteInitialDelay: TimeInterval = 0.5
    private static let deleteSlowestInterval: TimeInterval = 0.16
    private static let deleteFastestInterval: TimeInterval = 0.09
    /// After this many repeats a hold is clearly a bulk deletion, and whole
    /// words go rather than letters.
    private static let deleteWordThreshold = 16

    private func startDeleteTimer() {
        deleteTimer?.invalidate()
        deleteRepeatCount = 0
        deleteTimer = Timer.scheduledTimer(
            withTimeInterval: Self.deleteInitialDelay,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleNextDelete() }
        }
    }

    /// One repeat at a time, rescheduled at the ramped interval — a repeating
    /// timer cannot change its own period. Not private, so a test can step the
    /// ramp without waiting out real seconds of held Delete.
    func scheduleNextDelete() {
        deleteTimer?.invalidate()
        guard delegate?.keyGridShouldContinueDeleting(self) ?? true else {
            // The start of a line. Stopping here is what keeps a held Delete
            // from swallowing the paragraph above; continuing past it takes a
            // fresh press, which is the system's behaviour.
            endDeleteRepeat()
            return
        }
        deleteRepeatCount += 1
        let output: KeyboardOutput = deleteRepeatCount > Self.deleteWordThreshold
            ? .deleteWord
            : .deleteBackward
        feedback.deleteRepeated()
        delegate?.keyGrid(self, didProduce: output)

        // Eased from slow to fast over the first dozen repeats.
        let progress = min(CGFloat(deleteRepeatCount) / 12, 1)
        let interval = Self.deleteSlowestInterval
            - (Self.deleteSlowestInterval - Self.deleteFastestInterval) * Double(progress)
        deleteTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleNextDelete() }
        }
    }

    private func endDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteTimer = nil
        deleteRepeatCount = 0
    }

    // MARK: - Preview

    private func showPreview(for item: TrackedTouch) {
        guard metrics.showsPreview,
              item.key.spec.cap.isCharacter,
              let text = item.key.previewText
        else {
            recycle(item.preview)
            item.preview = nil
            return
        }

        let preview: KeyPreviewView
        if let existing = item.preview {
            preview = existing
        } else {
            preview = dequeuePreview()
            item.preview = preview
        }
        let frame = item.key.frame
        let width = max(frame.width * 1.5, frame.width + 22)
        let balloonHeight = frame.height * 1.25
        let x = min(max(frame.midX - width / 2, 2), bounds.width - width - 2)
        // The preview reaches down over the key rather than floating above a
        // gap: the neck is what joins the two on the system keyboard, and the
        // gap is the tell that gives a third-party keyboard away.
        preview.frame = CGRect(
            x: x,
            y: frame.minY - balloonHeight,
            width: width,
            height: balloonHeight + frame.height
        )
        preview.show(
            text,
            balloonHeight: balloonHeight,
            neck: CGRect(
                x: frame.minX - x,
                y: balloonHeight,
                width: frame.width,
                height: frame.height
            )
        )
        bringSubviewToFront(preview)
    }

#if DEBUG
    /// Shows a key's preview with no touch behind it, so the balloon can be
    /// rendered and looked at without installing the keyboard on a device.
    ///
    /// The throwaway `TrackedTouch` is deliberately not added to `tracked`: it
    /// carries no real `UITouch`, and live touch tracking must never see one.
    /// `showPreview` only reads the item, and the balloon it dequeues is a
    /// subview of the grid, so it survives for the render either way.
    func previewKeyForRendering(_ key: KeyView) {
        showPreview(for: TrackedTouch(touch: UITouch(), key: key, initialPoint: .zero))
    }
#endif

    /// Reused rather than allocated per touch; a fast typist would otherwise
    /// create and discard a view for every keystroke.
    private func dequeuePreview() -> KeyPreviewView {
        if let reused = previewPool.popLast() {
            reused.isHidden = false
            return reused
        }
        let preview = KeyPreviewView(palette: palette, metrics: metrics)
        addSubview(preview)
        return preview
    }

    private func recycle(_ preview: KeyPreviewView?) {
        guard let preview else { return }
        preview.isHidden = true
        // Two covers two-thumb typing; holding more would just retain views.
        guard previewPool.count < 2 else {
            preview.removeFromSuperview()
            return
        }
        previewPool.append(preview)
    }
}

extension KeyGridView: KeyViewAccessibilityDelegate {
    func keyView(_ key: KeyView, didChooseAlternative text: String) {
        delegate?.keyGrid(self, didProduce: .text(text))
        if shiftState == .on { shiftState = .off }
    }

    func keyViewDidRequestEmojiPanel(_ key: KeyView) {
        delegate?.keyGrid(self, didProduce: .emojiPanel)
    }
}

private extension KeyCap {
    /// Modifiers and deletion respond as the finger lands; characters wait for
    /// lift so a slide can still correct the target.
    var actsOnTouchDown: Bool {
        switch self {
        case .delete, .shift, .plane, .globe: true
        case .character, .space, .newline: false
        }
    }
}
