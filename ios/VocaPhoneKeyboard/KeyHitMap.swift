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
}
