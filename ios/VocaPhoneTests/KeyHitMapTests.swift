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

    /// A finger that lands near the edge of a key and rolls as it lifts — which
    /// is what typing at speed looks like — used to leave with the neighbour,
    /// because the effective targets meet on a knife edge. It now has to clear
    /// the key it pressed before the grid will hand it over.
    @Test func aRollWithinTheHysteresisKeepsTheKeyItPressed() {
        let hysteretic = KeyHitMap(targets: map.targets, hysteresis: 8)
        // 41 is already inside key 1's effective target, but only 1pt outside
        // key 0's slot.
        #expect(hysteretic.retarget(from: 0, at: 41) == nil)
        #expect(hysteretic.retarget(from: 0, at: 47) == nil)
    }

    /// A deliberate slide still lands: past the hysteresis the neighbour wins,
    /// which is the slide-to-correct gesture the keyboard has always had.
    @Test func aSlideBeyondTheHysteresisTakesTheNeighbour() {
        let hysteretic = KeyHitMap(targets: map.targets, hysteresis: 8)
        #expect(hysteretic.retarget(from: 0, at: 48) == 1)
    }

    /// Hysteresis is measured from the current key alone. Coming back onto the
    /// key the finger started on is never a re-target, however far it went.
    @Test func returningToTheOriginalKeyIsNotARetarget() {
        let hysteretic = KeyHitMap(targets: map.targets, hysteresis: 8)
        #expect(hysteretic.retarget(from: 0, at: 20) == nil)
    }

    /// The distance is to the nearest edge, so it is zero everywhere inside the
    /// key and grows in whichever direction the finger actually left.
    @Test func distanceToASlotIsZeroInsideItAndGrowsOutside() {
        let slot = CGRect(x: 0, y: 0, width: 40, height: 40)
        #expect(KeyHitMap.distance(from: slot, to: CGPoint(x: 20, y: 20)) == 0)
        #expect(KeyHitMap.distance(from: slot, to: CGPoint(x: 46, y: 20)) == 6)
        #expect(KeyHitMap.distance(from: slot, to: CGPoint(x: 20, y: -5)) == 5)
    }

    /// The hysteresis has to scale with the keys: a value that protects a 34pt
    /// portrait column would be a much smaller share of a 56pt iPad one, and
    /// the same roll would still slip through there.
    @Test func layoutDerivesAHysteresisFromItsOwnColumnWidth() {
        let metrics = KeyboardMetrics.resolved(for: UITraitCollection {
            $0.verticalSizeClass = .regular
        })
        let grid = KeyGridView(metrics: metrics, palette: KeyboardPalette(isDark: false))
        grid.frame = CGRect(x: 0, y: 0, width: 393, height: metrics.gridHeight)
        grid.layoutIfNeeded()

        // Wide enough that a keystroke's roll stays on its key, and narrow
        // enough that a deliberate slide to the next letter still arrives.
        #expect(grid.hitMap.hysteresis > metrics.columnGap)
        #expect(grid.hitMap.hysteresis < 12)
    }

    /// The whole point, in the geometry people actually type on: a finger that
    /// presses `d` a couple of points from its edge and skids six more must
    /// still produce `d`.
    @Test func aRollOffTheEdgeOfALetterStillTypesThatLetter() throws {
        let metrics = KeyboardMetrics.resolved(for: UITraitCollection {
            $0.verticalSizeClass = .regular
        })
        let grid = KeyGridView(metrics: metrics, palette: KeyboardPalette(isDark: false))
        grid.frame = CGRect(x: 0, y: 0, width: 393, height: metrics.gridHeight)
        grid.layoutIfNeeded()

        let d = try #require(grid.keyViews.first { $0.spec.cap == .character("d") })
        let index = try #require(grid.keyViews.firstIndex(of: d))
        let rolled = CGPoint(x: d.frame.maxX + 4, y: d.frame.midY)

        // The effective targets alone have already given the point away.
        #expect(grid.key(at: rolled, characterOnly: true)?.spec.cap == .character("f"))
        // The finger that pressed `d` keeps it.
        #expect(grid.hitMap.retargetIndex(from: index, at: rolled, characterOnly: true) == nil)
    }

    /// Two-thumb typists tap `123` with one thumb while the other is still on a
    /// letter. The switch used to release every tracked touch, so that letter
    /// was a keystroke the user typed and never saw.
    @Test func aPlaneSwitchKeepsTheFingerAlreadyDownOnALetter() throws {
        let delegate = KeyGridDelegateSpy()
        let grid = Self.makeLaidOutGrid(delegate: delegate)

        let q = try #require(grid.keyViews.first { $0.spec.cap == .character("q") })
        let planeKey = try #require(grid.keyViews.first { $0.spec.cap == .plane(.numbers) })

        let letter = StubTouch(at: q.frame.center)
        grid.touchesBegan([letter], with: nil)
        grid.touchesBegan([StubTouch(at: planeKey.frame.center)], with: nil)
        #expect(grid.plane == .numbers)

        grid.touchesEnded([letter], with: nil)
        #expect(delegate.insertedText == ["q"])
    }

    /// Pinned means frozen, not merely un-slidable: the plane it was moving
    /// across is gone, so a drag can no longer pick up whatever digit happens to
    /// have taken that spot.
    @Test func aPinnedFingerCommitsWhatItPressedAndIgnoresTheDrag() throws {
        let delegate = KeyGridDelegateSpy()
        let grid = Self.makeLaidOutGrid(delegate: delegate)

        let q = try #require(grid.keyViews.first { $0.spec.cap == .character("q") })
        let w = try #require(grid.keyViews.first { $0.spec.cap == .character("w") })
        let planeKey = try #require(grid.keyViews.first { $0.spec.cap == .plane(.numbers) })

        let letter = StubTouch(at: q.frame.center)
        grid.touchesBegan([letter], with: nil)
        grid.touchesBegan([StubTouch(at: planeKey.frame.center)], with: nil)

        letter.move(to: w.frame.center)
        grid.touchesMoved([letter], with: nil)
        grid.touchesEnded([letter], with: nil)

        #expect(delegate.insertedText == ["q"])
    }

    /// The finger that pressed `123` is pinned by its own switch like every
    /// other, but a plane key types nothing, so it must be replaced rather than
    /// left behind — otherwise its lift consumes the slide's entry and the
    /// symbol the finger slid onto never arrives.
    @Test func theFingerThatSwitchedPlanesStillSlidesOntoASymbol() throws {
        let delegate = KeyGridDelegateSpy()
        let grid = Self.makeLaidOutGrid(delegate: delegate)

        let planeKey = try #require(grid.keyViews.first { $0.spec.cap == .plane(.numbers) })
        let touch = StubTouch(at: planeKey.frame.center)
        grid.touchesBegan([touch], with: nil)

        let four = try #require(grid.keyViews.first { $0.spec.cap == .character("4") })
        touch.move(to: four.frame.center)
        grid.touchesMoved([touch], with: nil)
        grid.touchesEnded([touch], with: nil)

        #expect(delegate.insertedText == ["4"])
        // Typing a symbol this way returns to the plane the finger came from.
        #expect(grid.plane == .letters)
    }

    /// The reported bug, driven through the real touch path: a finger that
    /// presses `d` near its edge and skids as it lifts — every keystroke at
    /// speed — used to type `f`.
    @Test func aKeystrokeThatRollsOffTheEdgeStillTypesItsOwnLetter() throws {
        let delegate = KeyGridDelegateSpy()
        let grid = Self.makeLaidOutGrid(delegate: delegate)
        let d = try #require(grid.keyViews.first { $0.spec.cap == .character("d") })

        let touch = StubTouch(at: CGPoint(x: d.frame.maxX - 2, y: d.frame.midY))
        grid.touchesBegan([touch], with: nil)
        touch.move(to: CGPoint(x: d.frame.maxX + 4, y: d.frame.midY))
        grid.touchesMoved([touch], with: nil)
        grid.touchesEnded([touch], with: nil)

        #expect(delegate.insertedText == ["d"])
    }

    /// A deliberate slide to the next letter is a gesture people use to fix a
    /// target, and the hysteresis must not have eaten it.
    @Test func aDeliberateSlideToTheNextLetterStillRetargets() throws {
        let delegate = KeyGridDelegateSpy()
        let grid = Self.makeLaidOutGrid(delegate: delegate)
        let d = try #require(grid.keyViews.first { $0.spec.cap == .character("d") })
        let f = try #require(grid.keyViews.first { $0.spec.cap == .character("f") })

        let touch = StubTouch(at: d.frame.center)
        grid.touchesBegan([touch], with: nil)
        touch.move(to: f.frame.center)
        grid.touchesMoved([touch], with: nil)
        grid.touchesEnded([touch], with: nil)

        #expect(delegate.insertedText == ["f"])
    }

    /// With a second finger down the grid stops following a drag at all, because
    /// panels report two close contacts noisily and the finger that is lifting
    /// reads as a slide. Both fingers type what they pressed.
    @Test func aSecondFingerDownPinsBothToTheKeysTheyPressed() throws {
        let delegate = KeyGridDelegateSpy()
        let grid = Self.makeLaidOutGrid(delegate: delegate)
        let d = try #require(grid.keyViews.first { $0.spec.cap == .character("d") })
        let f = try #require(grid.keyViews.first { $0.spec.cap == .character("f") })
        let k = try #require(grid.keyViews.first { $0.spec.cap == .character("k") })

        let first = StubTouch(at: d.frame.center)
        let second = StubTouch(at: k.frame.center)
        grid.touchesBegan([first], with: nil)
        grid.touchesBegan([second], with: nil)

        // Far enough that a single finger would certainly have re-targeted.
        first.move(to: f.frame.center)
        grid.touchesMoved([first], with: nil)
        grid.touchesEnded([first], with: nil)
        grid.touchesEnded([second], with: nil)

        #expect(delegate.insertedText == ["d", "k"])
    }

    private static func makeLaidOutGrid(delegate: KeyGridDelegateSpy) -> KeyGridView {
        let metrics = KeyboardMetrics.resolved(for: UITraitCollection {
            $0.verticalSizeClass = .regular
        })
        let grid = KeyGridView(
            metrics: metrics,
            palette: KeyboardPalette(isDark: false),
            feedback: KeyboardFeedbackSpy()
        )
        grid.delegate = delegate
        grid.shiftState = .off
        grid.frame = CGRect(x: 0, y: 0, width: 393, height: metrics.gridHeight)
        grid.layoutIfNeeded()
        return grid
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

/// A `UITouch` that reports a location. UIKit only ever hands out real ones, and
/// the grid reads nothing from a touch but its identity, its timestamp and where
/// it is — so the touch paths can be driven end to end without a device.
private final class StubTouch: UITouch {
    private var point: CGPoint

    init(at point: CGPoint) {
        self.point = point
        super.init()
    }

    func move(to point: CGPoint) { self.point = point }

    override func location(in view: UIView?) -> CGPoint { point }
}

private extension KeyHitMap {
    /// The three-target fixture is one row 40pt tall, so every case in it varies
    /// only in x. Naming that keeps the assertions to the number under test.
    func retarget(from currentIndex: Int, at x: CGFloat) -> Int? {
        retargetIndex(from: currentIndex, at: CGPoint(x: x, y: 20), characterOnly: false)
    }
}
