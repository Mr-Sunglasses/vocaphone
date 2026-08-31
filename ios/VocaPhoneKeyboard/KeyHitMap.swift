import CoreGraphics

/// The effective targets for one laid-out keyboard plane.
///
/// Keys can visually leave a gutter between them while still claiming that
/// space for touch input. Keeping the selection rule separate from `UIView`
/// traversal makes that rule deterministic, testable, and shared by every
/// touch path. The visible geometry remains the source of truth; what the
/// language model contributes is a bounded nudge at the boundaries — see
/// ``likelihood``.
struct KeyHitMap {
    struct Target: Equatable {
        /// Stable layout order, used only when a point is exactly equidistant
        /// from two visual centres.
        let index: Int
        let frame: CGRect
        let hitRect: CGRect
        let isCharacter: Bool
        /// The lowercase letter this key types, for keys that type one. This is
        /// what ``likelihood`` is keyed by, so a plane change or a re-layout
        /// does not invalidate a prediction that is about letters rather than
        /// about positions.
        var character: Character?

        init(
            index: Int,
            frame: CGRect,
            hitRect: CGRect,
            isCharacter: Bool,
            character: Character? = nil
        ) {
            self.index = index
            self.frame = frame
            self.hitRect = hitRect
            self.isCharacter = isCharacter
            self.character = character
        }
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

    /// How likely each letter is to be the next one typed, from 0 to 1.
    ///
    /// This is the half of the touch model that geometry cannot supply. The
    /// system keyboard grows a key's *invisible* target when the language
    /// expects that letter — after "th", "e" claims more of the gutter than the
    /// "w" beside it — and it is a large part of why a finger landing between
    /// two keys is forgiven there and was not here.
    ///
    /// Deliberately a separate stored property rather than something baked into
    /// the targets: the targets change on layout, this changes on every
    /// keystroke, and rebuilding thirty frames per letter to carry a number
    /// would cost more than the correction is worth.
    var likelihood: [Character: Double] = [:]

    /// The most a fully expected letter may claim beyond its own boundary, as a
    /// share of the hysteresis distance.
    ///
    /// Small on purpose, and bounded by the same number that already decides how
    /// far a finger must travel to change keys. A prediction is allowed to
    /// settle a genuinely marginal touch; it is never allowed to take a touch
    /// that plainly landed on the neighbour, because a keyboard that types a
    /// letter the user can see they did not press is worse than one that is
    /// merely unforgiving.
    static let maximumBiasShare: CGFloat = 0.5

    init(targets: [Target], hysteresis: CGFloat = 0, likelihood: [Character: Double] = [:]) {
        self.targets = targets
        self.hysteresis = hysteresis
        self.likelihood = likelihood
    }

    /// How strongly this key is expected, from 0 (no opinion) to 1.
    func weight(of target: Target) -> Double {
        guard let character = target.character, !likelihood.isEmpty else { return 0 }
        return min(max(likelihood[character] ?? 0, 0), 1)
    }

    /// The target's claimed area, grown by however much the language expects it.
    func effectiveRect(of target: Target) -> CGRect {
        let grow = hysteresis * Self.maximumBiasShare * CGFloat(weight(of: target))
        guard grow > 0 else { return target.hitRect }
        return target.hitRect.insetBy(dx: -grow, dy: -grow)
    }

    /// The nearest visible centre among the targets claiming `point`.
    ///
    /// A gutter can land exactly on the midpoint between two keys. `targets` is
    /// in layout order and the comparison is strictly closer, so such a tie
    /// goes to the earlier key — the leftmost on a row — rather than to
    /// whatever order the view hierarchy happens to be in after previews and
    /// accessibility have moved subviews around.
    ///
    /// Expanded targets overlap, which is the point: where two keys both claim a
    /// point, the distance to each centre is scaled by how much the language
    /// expects it, and the expected one wins a contest it would otherwise have
    /// lost by a point or two.
    func targetIndex(at point: CGPoint, characterOnly: Bool) -> Int? {
        var winner: Target?
        var shortestDistance = CGFloat.greatestFiniteMagnitude

        for target in targets {
            guard (!characterOnly || target.isCharacter),
                  effectiveRect(of: target).contains(point)
            else { continue }

            let distance = hypot(
                point.x - target.frame.midX,
                point.y - target.frame.midY
            ) / (1 + CGFloat(weight(of: target)) * 0.12)
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
        // Leaving a key the language expects takes a little more travel; landing
        // on one takes a little less. The same bounded nudge as the expanded
        // target, expressed against the distance the finger has to clear.
        var required = hysteresis
        if !likelihood.isEmpty,
           let candidateTarget = targets.first(where: { $0.index == candidate })
        {
            let difference = weight(of: current) - weight(of: candidateTarget)
            required *= max(0, 1 + CGFloat(difference) * Self.maximumBiasShare)
        }
        guard Self.distance(from: current.frame, to: point) >= required else { return nil }
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
