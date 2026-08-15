import Testing
import UIKit

/// The trail is the only thing that tells a user the keyboard is following their
/// finger, and it is drawn every frame of a gesture. Both of those make it worth
/// pinning down: it has to taper the right way round, and it has to stop.
@MainActor
struct SwipeTrailTests {
    private static func traced(
        _ points: [CGPoint],
        from start: CFTimeInterval = 0,
        step: CFTimeInterval = 1.0 / 60
    ) -> SwipeTrail {
        var trail = SwipeTrail()
        guard let first = points.first else { return trail }
        trail.begin(at: first, time: start)
        for (index, point) in points.dropFirst().enumerated() {
            trail.append(point, time: start + step * CFTimeInterval(index + 1))
        }
        return trail
    }

    private static func line(count: Int, spacing: CGFloat = 12) -> [CGPoint] {
        (0..<count).map { CGPoint(x: CGFloat($0) * spacing, y: 40) }
    }

    // MARK: - Sampling

    /// A finger resting on a key delivers a stream of touches a fraction of a
    /// point apart. Keeping them would fill the buffer with round caps stacked
    /// on the same pixel, which costs a frame and shows nothing.
    @Test func pointsTooCloseTogetherAreDroppedAsTheSamePoint() {
        var trail = SwipeTrail()
        trail.begin(at: CGPoint(x: 10, y: 10), time: 0)
        trail.append(CGPoint(x: 10.4, y: 10.2), time: 0.01)
        #expect(trail.samples.count == 1)
        trail.append(CGPoint(x: 14, y: 10), time: 0.02)
        #expect(trail.samples.count == 2)
    }

    /// A long, slow trace must not grow the buffer without bound — the keyboard
    /// is killed for using memory, not for dropping a sample.
    @Test func theBufferIsCappedAndKeepsTheNewestSamples() {
        let trail = Self.traced(Self.line(count: SwipeTrail.sampleLimit + 40))
        #expect(trail.samples.count == SwipeTrail.sampleLimit)
        // The oldest went, not the newest: the fingertip is the part that has to
        // stay on screen.
        #expect(trail.samples.last?.point.x == CGFloat(SwipeTrail.sampleLimit + 39) * 12)
    }

    // MARK: - Ageing

    @Test func lifeFallsFromOneAtTheFingertipToZeroAtTheLifetime() {
        #expect(SwipeTrail.life(age: 0) == 1)
        #expect(SwipeTrail.life(age: SwipeTrail.lifetime / 2) == 0.5)
        #expect(SwipeTrail.life(age: SwipeTrail.lifetime) == 0)
        // A clock that jumps backwards must not produce a stroke wider than the
        // maximum; clamping at both ends is cheaper than trusting the caller.
        #expect(SwipeTrail.life(age: -1) == 1)
        #expect(SwipeTrail.life(age: 10) == 0)
    }

    /// The whole point of ageing: a trail left alone empties itself, which is
    /// what lets the view stop its display link instead of ticking forever.
    @Test func aTrailLeftAloneExpiresCompletely() {
        var trail = Self.traced(Self.line(count: 8))
        // `#expect` cannot call a mutating member, so each prune answers first.
        let survivesAShortPause = trail.prune(now: 0.2)
        #expect(survivesAShortPause)
        let survivesALifetime = trail.prune(now: SwipeTrail.lifetime + 0.2)
        #expect(!survivesALifetime)
        #expect(trail.isEmpty)
    }

    @Test func pruningKeepsTheRecentTailAndDropsTheRestOfTheWord() {
        // Twenty samples at 60 Hz spans a third of a second, so a prune at the
        // end of the lifetime keeps every one of them...
        var trail = Self.traced(Self.line(count: 20))
        trail.prune(now: SwipeTrail.lifetime - 0.001)
        #expect(trail.samples.count == 20)
        // ...and one taken a lifetime after the *first* sample keeps only what
        // the finger has drawn since.
        var older = Self.traced(Self.line(count: 20))
        older.prune(now: SwipeTrail.lifetime + 0.1)
        #expect(older.samples.count < 20)
        #expect(older.samples.allSatisfy { $0.point.x > 0 })
    }

    // MARK: - Drawing

    /// The stroke is widest and strongest under the fingertip. Getting this
    /// backwards would draw a comet pointing the wrong way, which is precisely
    /// the sort of thing that looks fine in a still and wrong in the hand.
    @Test func theStrokeTapersTowardsTheOlderEnd() {
        let trail = Self.traced(Self.line(count: 40))
        let strokes = trail.strokes(now: 39.0 / 60)
        #expect(strokes.count > 1)
        guard let oldest = strokes.first, let newest = strokes.last else { return }
        #expect(newest.width > oldest.width)
        #expect(newest.alpha > oldest.alpha)
        #expect(newest.width <= SwipeTrail.maximumWidth)
        #expect(oldest.width >= SwipeTrail.minimumWidth)
        // Monotonic all the way along, not merely at the two ends.
        #expect(zip(strokes, strokes.dropFirst()).allSatisfy { $0.width < $1.width })
    }

    /// The bands are drawn separately, so they have to share a point — otherwise
    /// the taper steps leave a sample-wide hole at each change of width.
    @Test func theBandsJoinRatherThanLeavingGapsInTheLine() {
        let trail = Self.traced(Self.line(count: 40))
        let strokes = trail.strokes(now: 39.0 / 60)
        for (earlier, later) in zip(strokes, strokes.dropFirst()) {
            #expect(earlier.points.last == later.points.first)
        }
        #expect(strokes.allSatisfy { $0.points.count > 1 })
    }

    /// A run per sample would blend its own round caps against its neighbours'
    /// twice at every joint, which draws as a string of beads rather than a
    /// line. There are far fewer runs than samples, by construction.
    @Test func theLineIsDrawnAsAHandfulOfRunsRatherThanOnePerSample() {
        let trail = Self.traced(Self.line(count: 40))
        #expect(trail.strokes(now: 39.0 / 60).count <= SwipeTrail.bandCount)
    }

    /// Never opaque: the trail is drawn over the very keys the user is aiming
    /// at, and a solid line across them would hide the next letter.
    @Test func theStrokeNeverFullyHidesTheKeysUnderIt() {
        let trail = Self.traced(Self.line(count: 30))
        for stroke in trail.strokes(now: 30.0 / 60) {
            #expect(stroke.alpha <= SwipeTrail.maximumAlpha)
            #expect(stroke.width <= SwipeTrail.maximumWidth)
        }
        #expect(SwipeTrail.maximumAlpha < 1)
    }

    @Test func aSinglePointDrawsNothing() {
        var trail = SwipeTrail()
        trail.begin(at: CGPoint(x: 5, y: 5), time: 0)
        #expect(trail.strokes(now: 0).isEmpty)
        #expect(SwipeTrail().strokes(now: 0).isEmpty)
    }

    /// The redraw area has to cover the round caps at the ends of the stroke, or
    /// a swipe leaves crumbs of line behind on the keys.
    @Test func theDirtyRectCoversTheWidestStrokeAroundThePath() {
        let trail = Self.traced([CGPoint(x: 40, y: 40), CGPoint(x: 100, y: 90)])
        let rect = trail.dirtyRect()
        #expect(rect.contains(CGPoint(x: 40, y: 40)))
        #expect(rect.contains(CGPoint(x: 100, y: 90)))
        #expect(rect.minX <= 40 - SwipeTrail.maximumWidth / 2)
        #expect(rect.maxY >= 90 + SwipeTrail.maximumWidth / 2)
        #expect(SwipeTrail().dirtyRect().isNull)
    }

    // MARK: - The view

    /// The trail sits over the keys, so anything it swallowed would be a letter
    /// the user meant to type.
    @Test func theTrailViewNeverTakesATouch() {
        let view = SwipeTrailView(color: .red)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        #expect(!view.isUserInteractionEnabled)
        #expect(view.hitTest(CGPoint(x: 100, y: 100), with: nil) == nil)
    }

    /// The grid keeps one trail view for the life of the keyboard and hands it
    /// every swipe, so beginning a second gesture must not draw the first one's
    /// path leading into it.
    @Test func aNewSwipeDoesNotInheritTheLastOnesPath() {
        var trail = Self.traced(Self.line(count: 10))
        trail.begin(at: CGPoint(x: 200, y: 20), time: 5)
        #expect(trail.samples.count == 1)
        #expect(trail.samples.first?.point.x == 200)
    }
}
