import UIKit

enum KeyboardOutput {
    case text(String)
    case space
    case newline
    case deleteBackward
    case deleteWord
    /// Carries the globe key itself so the keyboard picker can anchor to it.
    case nextInputMode(UIView, UIEvent?)
}

@MainActor
protocol KeyGridViewDelegate: AnyObject {
    func keyGrid(_ grid: KeyGridView, didProduce output: KeyboardOutput)
    func keyGridDidChangeShift(_ grid: KeyGridView)
}

/// The typing area. Owns hit testing, so keys can be slid between and their
/// touch targets can spill into the gutters — both impossible with one control
/// per key reacting to `touchUpInside`.
final class KeyGridView: UIView {
    weak var delegate: (any KeyGridViewDelegate)?

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

    var leadingPunctuation = "," {
        didSet { if leadingPunctuation != oldValue { rebuild() } }
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
    private var tracked: [TrackedTouch] = []
    private var deleteTimer: Timer?
    private var deleteRepeatCount = 0
    private var lastShiftTapAt: Date?

    private final class TrackedTouch {
        let touch: UITouch
        var key: KeyView
        let allowsSlide: Bool
        var preview: KeyPreviewView?

        init(touch: UITouch, key: KeyView) {
            self.touch = touch
            self.key = key
            allowsSlide = key.spec.cap.isCharacter
        }
    }

    init(metrics: KeyboardMetrics, palette: KeyboardPalette) {
        self.metrics = metrics
        self.palette = palette
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
        let available = bounds.width - 2 * metrics.sideInset
        // Every row resolves against the width of one letter column from the
        // ten-key reference row, which is what keeps columns aligned vertically.
        let unit = (available - 9 * metrics.columnGap) / 10
        guard unit > 0 else { return }

        var keyIndex = 0
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
                key.frame = CGRect(x: x, y: y, width: width, height: metrics.keyHeight)
                key.hitRect = hitRect(
                    for: key.frame,
                    isLeading: column == 0,
                    isTrailing: column == widths.count - 1,
                    isTopRow: rowIndex == 0,
                    isBottomRow: rowIndex == rows.count - 1
                )
                x += width + metrics.columnGap
                keyIndex += 1
            }
            y += metrics.keyHeight + metrics.rowGap
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
        endDeleteRepeat()
        releaseTouches()
        for (_, plane) in planeCache {
            plane.views.forEach { $0.removeFromSuperview() }
        }
        planeCache.removeAll()
        previewPool.forEach { $0.removeFromSuperview() }
        previewPool.removeAll()
        keyViews.removeAll()
        rows.removeAll()
        activatePlane()
    }

    private func activatePlane() {
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
        updateKeys()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func releaseTouches() {
        for item in tracked {
            item.key.isHighlighted = false
            recycle(item.preview)
            item.preview = nil
        }
        tracked.removeAll()
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
            guard let key = key(at: touch.location(in: self), characterOnly: false)
            else { continue }
            let item = TrackedTouch(touch: touch, key: key)
            tracked.append(item)
            key.isHighlighted = true
            UIDevice.current.playInputClick()
            showPreview(for: item)
            if key.spec.cap.actsOnTouchDown {
                performTouchDownAction(for: key, event: event)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let item = tracked.first(where: { $0.touch === touch }) else { continue }
            let point = touch.location(in: self)

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
        for touch in touches {
            guard let index = tracked.firstIndex(where: { $0.touch === touch }) else { continue }
            let item = tracked.remove(at: index)
            let shouldCommit = commit && item.key.isHighlighted
            item.key.isHighlighted = false
            recycle(item.preview)
            item.preview = nil
            if item.key.spec.cap == .delete { endDeleteRepeat() }
            guard shouldCommit, !item.key.spec.cap.actsOnTouchDown else { continue }
            commitKey(item.key)
        }
    }

    private func commitKey(_ key: KeyView) {
        switch key.spec.cap {
        case .character:
            guard let text = key.previewText else { return }
            delegate?.keyGrid(self, didProduce: .text(text))
            if shiftState == .on { shiftState = .off }
        case .space:
            delegate?.keyGrid(self, didProduce: .space)
        case .newline:
            delegate?.keyGrid(self, didProduce: .newline)
        default:
            break
        }
    }

    private func performTouchDownAction(for key: KeyView, event: UIEvent?) {
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

    private func toggleShift() {
        let now = Date()
        let isDoubleTap = lastShiftTapAt.map { now.timeIntervalSince($0) < 0.35 } ?? false
        lastShiftTapAt = now
        shiftState = isDoubleTap ? .locked : (shiftState == .off ? .on : .off)
    }

    private func key(at point: CGPoint, characterOnly: Bool) -> KeyView? {
        var closest: KeyView?
        var shortestDistance = CGFloat.greatestFiniteMagnitude
        for key in keyViews {
            if characterOnly, !key.spec.cap.isCharacter { continue }
            guard key.hitRect.contains(point) else { continue }
            // Gutters belong to both neighbours, so ties go to the nearer centre.
            let distance = hypot(point.x - key.frame.midX, point.y - key.frame.midY)
            if distance < shortestDistance {
                shortestDistance = distance
                closest = key
            }
        }
        return closest
    }

    // MARK: - Delete repeat

    private func startDeleteTimer() {
        deleteTimer?.invalidate()
        deleteRepeatCount = 0
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.beginDeleteRepeat() }
        }
    }

    private func beginDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deleteRepeatCount += 1
                // Sustained holds escalate to whole words, so clearing a long
                // field does not take dozens of seconds.
                let output: KeyboardOutput = self.deleteRepeatCount > 18
                    ? .deleteWord
                    : .deleteBackward
                self.delegate?.keyGrid(self, didProduce: output)
            }
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
        preview.show(text)

        let frame = item.key.frame
        let width = max(frame.width * 1.5, frame.width + 22)
        let height = frame.height * 1.25
        let x = min(max(frame.midX - width / 2, 2), bounds.width - width - 2)
        preview.frame = CGRect(x: x, y: frame.minY - height - 6, width: width, height: height)
        bringSubviewToFront(preview)
    }

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
