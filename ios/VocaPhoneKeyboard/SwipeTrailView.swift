import QuartzCore
import UIKit

/// The sampled finger path behind a swipe, aged so the tail retracts on its own.
///
/// Pure, and driven by an injected clock, so the shape of the trail can be
/// tested without a touch or a display link.
///
/// A trail that simply accumulated points would draw the whole word as one flat
/// scribble, which is both slower to render every frame and harder to read: what
/// tells the user the recogniser is following them is the *recent* part of the
/// stroke. So each sample carries its own age, and the width and opacity of the
/// line fall away behind the finger.
struct SwipeTrail: Equatable {
    struct Sample: Equatable {
        var point: CGPoint
        var time: CFTimeInterval
    }

    /// One drawn piece of the line: a run of points at a single width and
    /// opacity. The trail tapers because it is several of these end to end.
    ///
    /// A run rather than a segment per sample, because a translucent stroke
    /// drawn as ninety separate line segments blends its own round caps against
    /// each other twice at every joint — which renders as a string of beads
    /// down the middle of the line instead of a stroke. Within a run there is
    /// one path, one width, and therefore no seam at all.
    struct Stroke: Equatable {
        var points: [CGPoint]
        var width: CGFloat
        var alpha: CGFloat
    }

    /// How long a point stays on screen after the finger has passed it. Long
    /// enough to see the shape of the word, short enough that the trail never
    /// becomes a drawing.
    static let lifetime: CFTimeInterval = 0.45
    /// Widest at the fingertip, narrowest at the vanishing tail.
    static let maximumWidth: CGFloat = 8.5
    static let minimumWidth: CGFloat = 1.5
    /// The strongest the line ever gets. A fully opaque stroke hides the letters
    /// the user is trying to aim at, which is the one thing it must not do.
    static let maximumAlpha: CGFloat = 0.9
    /// Samples closer together than this are the same point as far as the eye is
    /// concerned, and dropping them keeps a slow swipe from filling the buffer
    /// with dozens of overlapping round caps.
    static let minimumSpacing: CGFloat = 1.5
    /// A hard ceiling, so a long meandering trace cannot grow without bound.
    /// At 60 Hz this is more than a full lifetime's worth of samples.
    static let sampleLimit = 96
    /// How many widths the taper is quantised to. Enough that the line reads as
    /// continuously tapering, few enough that the whole trail is a handful of
    /// draw calls on a keyboard that has a frame to spare and not much else.
    static let bandCount = 8

    private(set) var samples: [Sample] = []

    var isEmpty: Bool { samples.isEmpty }

    mutating func begin(at point: CGPoint, time: CFTimeInterval) {
        samples = [Sample(point: point, time: time)]
    }

    mutating func append(_ point: CGPoint, time: CFTimeInterval) {
        if let last = samples.last {
            let dx = point.x - last.point.x
            let dy = point.y - last.point.y
            guard (dx * dx + dy * dy).squareRoot() >= Self.minimumSpacing else { return }
        }
        samples.append(Sample(point: point, time: time))
        if samples.count > Self.sampleLimit {
            samples.removeFirst(samples.count - Self.sampleLimit)
        }
    }

    mutating func clear() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Drops everything the user can no longer see. Returns whether anything is
    /// left, which is what tells the view when to stop its display link.
    @discardableResult
    mutating func prune(now: CFTimeInterval) -> Bool {
        samples.removeAll { now - $0.time >= Self.lifetime }
        return !samples.isEmpty
    }

    /// How alive a sample is, from 1 at the fingertip to 0 as it expires.
    static func life(age: CFTimeInterval) -> CGFloat {
        guard age > 0 else { return 1 }
        guard age < lifetime else { return 0 }
        return CGFloat(1 - age / lifetime)
    }

    /// Which of the ``bandCount`` widths a sample of this age is drawn at,
    /// counting from 0 at the vanishing tail.
    static func band(forLife life: CGFloat) -> Int {
        min(max(Int(life * CGFloat(bandCount)), 0), bandCount - 1)
    }

    /// The width and opacity a whole band is drawn at: its middle, so the
    /// quantisation neither reaches full strength early nor loses the tip.
    static func appearance(ofBand band: Int) -> (width: CGFloat, alpha: CGFloat) {
        let life = (CGFloat(band) + 0.5) / CGFloat(bandCount)
        return (
            minimumWidth + (maximumWidth - minimumWidth) * life,
            maximumAlpha * life
        )
    }

    /// The line to draw, oldest run first.
    ///
    /// Consecutive runs share a point, so the bands meet rather than leaving a
    /// gap the width of a sample at each step of the taper.
    func strokes(now: CFTimeInterval) -> [Stroke] {
        guard samples.count > 1 else { return [] }
        var strokes: [Stroke] = []
        var currentBand = Self.band(forLife: Self.life(age: now - samples[0].time))
        var points: [CGPoint] = [samples[0].point]
        for sample in samples.dropFirst() {
            let band = Self.band(forLife: Self.life(age: now - sample.time))
            if band != currentBand {
                points.append(sample.point)
                let appearance = Self.appearance(ofBand: currentBand)
                strokes.append(
                    Stroke(points: points, width: appearance.width, alpha: appearance.alpha)
                )
                // The new run picks up where the last one ended.
                points = [sample.point]
                currentBand = band
            } else {
                points.append(sample.point)
            }
        }
        if points.count > 1 {
            let appearance = Self.appearance(ofBand: currentBand)
            strokes.append(
                Stroke(points: points, width: appearance.width, alpha: appearance.alpha)
            )
        }
        return strokes
    }

    /// The area the drawn trail covers, padded by half the widest stroke so a
    /// round cap at the edge is never clipped. `.null` when there is nothing to
    /// draw, which a caller can pass straight to `setNeedsDisplay(_:)`.
    func dirtyRect() -> CGRect {
        guard let first = samples.first else { return .null }
        var rect = CGRect(origin: first.point, size: .zero)
        for sample in samples.dropFirst() {
            rect = rect.union(CGRect(origin: sample.point, size: .zero))
        }
        return rect.insetBy(dx: -Self.maximumWidth, dy: -Self.maximumWidth)
    }
}

/// Draws the trail over the keys while a swipe is in flight.
///
/// The keyboard could recognise swipes without this — and did — but a gesture
/// with no visible response is one the user cannot learn. The system keyboard
/// draws the same fading stroke, and it is what makes the difference between
/// "this keyboard supports swiping" and "this keyboard is following my finger".
///
/// Never takes touches: ``KeyGridView`` owns hit testing, and a view over the
/// keys that could swallow one would break typing to decorate it.
@MainActor
final class SwipeTrailView: UIView {
    var color: UIColor {
        didSet { if color != oldValue, !trail.isEmpty { setNeedsDisplay() } }
    }

    private var trail = SwipeTrail()
    private var displayLink: CADisplayLink?
    /// CADisplayLink retains its target, so the view cannot be its own — that is
    /// a cycle that outlives the keyboard and keeps redrawing a dead trail.
    ///
    /// The proxy also retires the link once its view is gone. A keyboard torn
    /// down mid-swipe would otherwise leave a display link ticking forever, at
    /// the display's full rate, in a process iOS already kills for using memory.
    @MainActor
    private final class LinkProxy: NSObject {
        weak var view: SwipeTrailView?
        var link: CADisplayLink?

        @objc func tick() {
            guard let view else {
                link?.invalidate()
                link = nil
                return
            }
            view.tick()
        }
    }

    init(color: UIColor) {
        self.color = color
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Tracking

    func begin(at point: CGPoint) {
        trail.begin(at: point, time: CACurrentMediaTime())
        startLink()
    }

    func extend(to point: CGPoint) {
        guard !trail.isEmpty else { return }
        trail.append(point, time: CACurrentMediaTime())
        startLink()
    }

    /// The finger has lifted. Nothing is cleared: the tail fades out in the same
    /// motion it had while being drawn, which is what makes the lift feel like
    /// the end of a gesture rather than a cut.
    func end() {
        // The link is already running and will stop itself once the last sample
        // has expired.
        startLink()
    }

    /// Removes the trail at once, for a keyboard being torn down or a gesture
    /// the system cancelled. A trail left behind reappears over the next field.
    func cancel() {
        guard !trail.isEmpty else { return }
        let dirty = trail.dirtyRect()
        trail.clear()
        stopLink()
        setNeedsDisplay(dirty)
    }

    // MARK: - Animation

    private func startLink() {
        guard displayLink == nil else { return }
        let proxy = LinkProxy()
        proxy.view = self
        let link = CADisplayLink(target: proxy, selector: #selector(LinkProxy.tick))
        // The trail is a direct-manipulation response, so it asks for the
        // display's full rate; anything slower reads as the finger outrunning it.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        proxy.link = link
        displayLink = link
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tick() {
        // Measured before the prune, so the pixels the expiring tail is about to
        // vacate are part of what gets redrawn.
        let dirty = trail.dirtyRect()
        if !trail.prune(now: CACurrentMediaTime()) { stopLink() }
        guard !dirty.isNull else { return }
        setNeedsDisplay(dirty)
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let components = color.cgColor
        for stroke in trail.strokes(now: CACurrentMediaTime()) {
            guard stroke.alpha > 0.01, stroke.points.count > 1 else { continue }
            context.setStrokeColor(components.copy(alpha: stroke.alpha) ?? components)
            context.setLineWidth(stroke.width)
            context.addLines(between: stroke.points)
            context.strokePath()
        }
    }
}
