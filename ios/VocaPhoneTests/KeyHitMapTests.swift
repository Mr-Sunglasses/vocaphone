import Testing
import UIKit

@MainActor
struct KeyHitMapTests {
    private let map = KeyHitMap(targets: [
        KeyHitMap.Target(
            index: 0,
            frame: CGRect(x: 0, y: 0, width: 40, height: 40),
            hitRect: CGRect(x: 0, y: 0, width: 45, height: 40),
            isCharacter: true
        ),
        KeyHitMap.Target(
            index: 1,
            frame: CGRect(x: 45, y: 0, width: 40, height: 40),
            hitRect: CGRect(x: 40, y: 0, width: 45, height: 40),
            isCharacter: true
        ),
        KeyHitMap.Target(
            index: 2,
            frame: CGRect(x: 90, y: 0, width: 40, height: 40),
            hitRect: CGRect(x: 85, y: 0, width: 45, height: 40),
            isCharacter: false
        ),
    ])

    @Test func gutterBelongsToTheNearestVisibleCentre() {
        #expect(map.targetIndex(at: CGPoint(x: 41, y: 20), characterOnly: false) == 0)
        #expect(map.targetIndex(at: CGPoint(x: 44, y: 20), characterOnly: false) == 1)
    }

    @Test func exactBoundaryTieUsesStableLayoutOrder() {
        // Both targets claim 42.5 and their centres are equally distant, so the
        // earlier key in layout order wins rather than whichever subview the
        // hierarchy happened to hold last.
        #expect(map.targetIndex(at: CGPoint(x: 42.5, y: 20), characterOnly: false) == 0)
    }

    @Test func characterOnlyQueriesNeverResolveAFunctionKey() {
        #expect(map.targetIndex(at: CGPoint(x: 110, y: 20), characterOnly: false) == 2)
        #expect(map.targetIndex(at: CGPoint(x: 110, y: 20), characterOnly: true) == nil)
    }

    @Test func pointsOutsideEveryEffectiveTargetDoNotResolve() {
        #expect(map.targetIndex(at: CGPoint(x: -1, y: 20), characterOnly: false) == nil)
        #expect(map.targetIndex(at: CGPoint(x: 200, y: 20), characterOnly: false) == nil)
    }

    /// `touchesBegan` walks an unordered set, so a second finger can land in the
    /// same event that switched planes. If the switch left the map empty until
    /// the next layout pass, that keystroke would resolve to nothing and be
    /// silently dropped — which is what two-thumb typing looks like.
    @Test func changingPlanesResolvesTheNewLayoutImmediately() throws {
        let metrics = KeyboardMetrics.resolved(for: UITraitCollection {
            $0.verticalSizeClass = .regular
        })
        let grid = KeyGridView(metrics: metrics, palette: KeyboardPalette(isDark: false))
        grid.frame = CGRect(x: 0, y: 0, width: 393, height: metrics.gridHeight)
        grid.layoutIfNeeded()

        let oldKey = try #require(grid.keyViews.first { $0.spec.cap == .character("q") })
        let oldPoint = oldKey.frame.center
        #expect(grid.key(at: oldPoint, characterOnly: false)?.spec.cap == .character("q"))

        grid.plane = .numbers
        #expect(grid.key(at: oldPoint, characterOnly: false)?.spec.cap == .character("1"))
    }

    /// The plane key acts on touch-down, and the switch releases every tracked
    /// touch. The hold used to hang off that touch, so it was cancelled before
    /// it could ever fire and the panel was unreachable by its own gesture.
    @Test func holdingThePlaneKeyOpensTheEmojiPanelAndUndoesTheSwitch() {
        let feedback = KeyboardFeedbackSpy()
        let delegate = KeyGridDelegateSpy()
        let grid = Self.makeGrid(feedback: feedback, delegate: delegate)

        grid.plane = .letters
        grid.beginPlaneHold(at: .zero)
        // What the touch-down action does the instant the finger lands.
        grid.plane = .numbers
        grid.completePlaneHold()

        #expect(grid.plane == .letters)
        #expect(delegate.outputs == ["emojiPanel"])
        #expect(feedback.events == [.selectionChanged])
    }

    /// A held Delete is a stream of deletions. Sounding only the first press
    /// makes a long hold read as a keyboard that has stopped responding.
    @Test func everyDeleteRepeatReportsItsOwnFeedback() {
        let feedback = KeyboardFeedbackSpy()
        let delegate = KeyGridDelegateSpy()
        let grid = Self.makeGrid(feedback: feedback, delegate: delegate)

        grid.scheduleNextDelete()
        grid.scheduleNextDelete()

        #expect(feedback.events == [.deleteRepeated, .deleteRepeated])
        #expect(delegate.outputs == ["deleteBackward", "deleteBackward"])
        grid.endActiveInteractions()
    }

    /// Shift and Delete render inset to leave the native moat around them. The
    /// moat is cosmetic: every point out to the slot boundary still belongs to
    /// the modifier, which is what `visibleFrame` promises and what a thumb
    /// aiming at the edge of Shift depends on.
    @Test func theMoatAroundShiftIsCosmeticAndKeepsItsTouchTarget() throws {
        let metrics = KeyboardMetrics.resolved(for: UITraitCollection {
            $0.verticalSizeClass = .regular
        })
        let grid = KeyGridView(metrics: metrics, palette: KeyboardPalette(isDark: false))
        grid.frame = CGRect(x: 0, y: 0, width: 393, height: metrics.gridHeight)
        grid.layoutIfNeeded()

        let shift = try #require(grid.keyViews.first { $0.spec.cap == .shift })
        // Without an inset there is no moat and nothing to protect.
        #expect(shift.frame.width < shift.hitRect.width - metrics.columnGap)

        let y = shift.frame.midY
        var x = shift.frame.maxX + 0.5
        while x < shift.hitRect.maxX {
            #expect(grid.key(at: CGPoint(x: x, y: y), characterOnly: false)?.spec.cap == .shift)
            x += 0.5
        }
    }

    /// Where two effective targets genuinely overlap, the winner is decided by
    /// the layout slot rather than the shrunken visual frame — otherwise a key
    /// that renders inset would be aimed at as though it were smaller than the
    /// area it actually claims.
    @Test func overlappingTargetsResolveByTheLayoutSlot() {
        let inset = KeyHitMap(targets: [
            // A modifier whose slot spans 0...60 but which renders 0...40.
            KeyHitMap.Target(
                index: 0,
                frame: CGRect(x: 0, y: 0, width: 60, height: 40),
                hitRect: CGRect(x: 0, y: 0, width: 70, height: 40),
                isCharacter: false
            ),
            KeyHitMap.Target(
                index: 1,
                frame: CGRect(x: 66, y: 0, width: 34, height: 40),
                hitRect: CGRect(x: 50, y: 0, width: 50, height: 40),
                isCharacter: true
            ),
        ])
        // 54 lies inside both hit rects. Measured from the slot centres, 30 and
        // 83, the modifier is nearer; measured from a 0...40 visual centre of
        // 20 it would lose the point to its neighbour.
        #expect(inset.targetIndex(at: CGPoint(x: 54, y: 20), characterOnly: false) == 0)
    }

    /// Sliding off Shift onto a letter types one capital and returns to
    /// lowercase — the reflex gesture the system keyboard has always had.
    @Test func slidingOffShiftTypesOneCapitalThenReleasesShift() throws {
        let feedback = KeyboardFeedbackSpy()
        let delegate = KeyGridDelegateSpy()
        let grid = Self.makeGrid(feedback: feedback, delegate: delegate)
        grid.shiftState = .on

        let landed = try #require(grid.keyViews.first { $0.spec.cap == KeyCap.character("q") })
        #expect(grid.completeKeyInteraction(landed, shouldCommit: true))

        #expect(delegate.insertedText == ["Q"])
        #expect(grid.shiftState == .off)
    }

    /// A locked Shift is a deliberate state, so a slide off it does not undo it.
    @Test func slidingOffALockedShiftKeepsCapsLock() throws {
        let grid = Self.makeGrid(feedback: KeyboardFeedbackSpy(), delegate: KeyGridDelegateSpy())
        grid.shiftState = .locked

        let landed = try #require(grid.keyViews.first { $0.spec.cap == KeyCap.character("q") })
        #expect(grid.completeKeyInteraction(landed, shouldCommit: true))
        #expect(grid.shiftState == .locked)
    }

    private static func makeGrid(
        feedback: KeyboardFeedbackSpy,
        delegate: KeyGridDelegateSpy
    ) -> KeyGridView {
        let metrics = KeyboardMetrics.resolved(for: UITraitCollection {
            $0.verticalSizeClass = .regular
        })
        let grid = KeyGridView(
            metrics: metrics,
            palette: KeyboardPalette(isDark: false),
            feedback: feedback
        )
        grid.delegate = delegate
        return grid
    }

    @Test func cancelledAndSlideCorrectedKeysReportOnlyTheFinalCommit() throws {
        let feedback = KeyboardFeedbackSpy()
        let delegate = KeyGridDelegateSpy()
        let metrics = KeyboardMetrics.resolved(for: UITraitCollection {
            $0.verticalSizeClass = .regular
        })
        let grid = KeyGridView(
            metrics: metrics,
            palette: KeyboardPalette(isDark: false),
            feedback: feedback
        )
        grid.delegate = delegate
        grid.shiftState = .off

        let initial = try #require(grid.keyViews.first { $0.spec.cap == .character("q") })
        let corrected = try #require(grid.keyViews.first { $0.spec.cap == .character("w") })
        grid.completeKeyInteraction(initial, shouldCommit: false)
        #expect(feedback.events.isEmpty)
        #expect(delegate.insertedText.isEmpty)

        grid.completeKeyInteraction(corrected, shouldCommit: true)
        #expect(feedback.events == [.textCommitted])
        #expect(delegate.insertedText == ["w"])
    }
}

private final class KeyboardFeedbackSpy: KeyboardFeedbackProviding {
    enum Event: Equatable {
        case keyPressed
        case textCommitted
        case keyActionCommitted
        case deleteRepeated
        case selectionChanged
    }

    private(set) var events: [Event] = []

    func keyPressed() { events.append(.keyPressed) }
    func textCommitted() { events.append(.textCommitted) }
    func keyActionCommitted() { events.append(.keyActionCommitted) }
    func deleteRepeated() { events.append(.deleteRepeated) }
    func selectionChanged() { events.append(.selectionChanged) }
    func action() {}
    func swipeBegan() {}
    func swipeCommitted() {}
}

private final class KeyGridDelegateSpy: KeyGridViewDelegate {
    private(set) var insertedText: [String] = []
    private(set) var outputs: [String] = []

    func keyGrid(_ grid: KeyGridView, didProduce output: KeyboardOutput) {
        if case let .text(text) = output { insertedText.append(text) }
        switch output {
        case .emojiPanel: outputs.append("emojiPanel")
        case .deleteBackward: outputs.append("deleteBackward")
        default: break
        }
    }

    func keyGridDidChangeShift(_ grid: KeyGridView) {}
    func keyGridShouldContinueDeleting(_ grid: KeyGridView) -> Bool { true }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
