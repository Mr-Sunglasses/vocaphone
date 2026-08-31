import CoreGraphics

/// The effective targets for one laid-out keyboard plane.
///
/// Keys can visually leave a gutter between them while still claiming that
/// space for touch input. Keeping the selection rule separate from `UIView`
/// traversal makes that rule deterministic, testable, and shared by every
/// touch path. The visible geometry remains the source of truth; this type does
/// not invent personalised or language-aware correction.
struct KeyHitMap {
    struct Target: Equatable {
        /// Stable layout order, used only when a point is exactly equidistant
        /// from two visual centres.
        let index: Int
        let frame: CGRect
        let hitRect: CGRect
        let isCharacter: Bool
    }

    let targets: [Target]

    /// How far past the edge of the key it is already on a finger must travel
    /// before the grid hands the touch to a neighbour.
    ///
    /// Without this a boundary is a knife edge: a finger that lands two points
    /// inside `d` and rolls six points right as it lifts — which is what every
    /// fast keystroke does — leaves with `f`. The system keyboards do not
    /// re-target on the boundary either. Android's is the published one:
    /// `config_key_hysteresis_distance` is 8dp measured from the *edge of the
    /// current key*, and `PointerTracker.isMajorEnoughMoveToBeOnNewKey` refuses
    /// the new key until the finger clears it.
    ///
    /// Zero restores the knife edge, and is only the default so that callers
    /// building a map for a query that has no current key need not supply one.
    let hysteresis: CGFloat

    init(targets: [Target], hysteresis: CGFloat = 0) {
        self.targets = targets
        self.hysteresis = hysteresis
    }

    /// The nearest visible centre among the targets claiming `point`.
    ///
    /// A gutter can land exactly on the midpoint between two keys. `targets` is
    /// in layout order and the comparison is strictly closer, so such a tie
    /// goes to the earlier key — the leftmost on a row — rather than to
    /// whatever order the view hierarchy happens to be in after previews and
    /// accessibility have moved subviews around.
    func targetIndex(at point: CGPoint, characterOnly: Bool) -> Int? {
        var winner: Target?
        var shortestDistance = CGFloat.greatestFiniteMagnitude

        for target in targets {
            guard (!characterOnly || target.isCharacter), target.hitRect.contains(point) else {
                continue
            }

            let distance = hypot(
                point.x - target.frame.midX,
                point.y - target.frame.midY
            )
            if distance < shortestDistance {
                winner = target
                shortestDistance = distance
            }
        }

        return winner?.index
    }

    /// The target a finger already on `currentIndex` should move to, or `nil`
    /// to stay where it is.
    ///
    /// Distance is measured from the current key's layout slot rather than from
    /// its effective target, because the effective targets tile the plane: they
    /// meet at the middle of the gutter, so measuring from them would give a
    /// key at the edge of the keyboard — whose target runs out to the bounds —
    /// far more protection than one in the middle of a row.
    func retargetIndex(from currentIndex: Int, at point: CGPoint, characterOnly: Bool) -> Int? {
        guard let candidate = targetIndex(at: point, characterOnly: characterOnly),
              candidate != currentIndex
        else { return nil }
        guard let current = targets.first(where: { $0.index == currentIndex }) else {
            return candidate
        }
        guard Self.distance(from: current.frame, to: point) >= hysteresis else { return nil }
        return candidate
    }

    /// How far `point` lies outside `rect`; zero anywhere inside it.
    static func distance(from rect: CGRect, to point: CGPoint) -> CGFloat {
        hypot(
            max(rect.minX - point.x, 0, point.x - rect.maxX),
            max(rect.minY - point.y, 0, point.y - rect.maxY)
        )
    }
}
