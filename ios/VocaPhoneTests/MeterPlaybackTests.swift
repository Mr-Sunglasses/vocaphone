import CoreGraphics
import Testing
import UIKit

/// The waveform's rhythm. Levels arrive five at a time, four times a second;
/// what a tester called mechanical was the bars moving on that beat.
struct MeterPlaybackTests {
    private static let burst: [Float] = [0.2, 0.4, 0.6, 0.8, 1.0]

    @Test func aBurstIsPlayedOutOneLevelAtATime() {
        var playback = MeterPlayback(barCount: 15)
        _ = playback.advance(to: 0, levels: [], appendedCount: 0, epoch: 0, isHeld: false, reduceMotion: false)
        _ = playback.advance(
            to: 0.001, levels: Self.burst, appendedCount: 5, epoch: 0, isHeld: false, reduceMotion: false
        )
        // The first level plays as it arrives; the other four wait their turn.
        #expect(playback.queue.count == 4)
        #expect(playback.released.last == CGFloat(Float(0.2)))

        var time = 0.001
        for _ in 0..<12 {
            time += 1.0 / 60
            _ = playback.advance(
                to: time, levels: Self.burst, appendedCount: 5, epoch: 0, isHeld: false, reduceMotion: false
            )
        }
        // A fifth of a second later — four releases at twenty a second.
        #expect(playback.queue.isEmpty)
        #expect(Array(playback.released.suffix(5)) == [0.2, 0.4, 0.6, 0.8, 1.0].map { CGFloat(Float($0)) })
    }

    @Test func barsEaseTowardsALevelRatherThanJumpingToIt() {
        var playback = MeterPlayback(barCount: 15)
        _ = playback.advance(to: 0, levels: [], appendedCount: 0, epoch: 0, isHeld: false, reduceMotion: false)
        let first = playback.advance(
            to: 0.016, levels: [1], appendedCount: 1, epoch: 0, isHeld: false, reduceMotion: false
        )
        // Part of the way up after one frame, not all of it.
        #expect(first[14] > 0)
        #expect(first[14] < 0.45)

        var settled = first
        var time = 0.016
        for _ in 0..<30 {
            time += 1.0 / 60
            settled = playback.advance(
                to: time, levels: [1], appendedCount: 1, epoch: 0, isHeld: false, reduceMotion: false
            )
        }
        // Settled close to the level by then.
        #expect(settled[14] > 0.4)
    }

    @Test func aBacklogIsTrimmedRatherThanReplayed() {
        var playback = MeterPlayback(barCount: 15)
        _ = playback.advance(to: 0, levels: [], appendedCount: 0, epoch: 0, isHeld: false, reduceMotion: false)
        let backlog = [Float](repeating: 0.5, count: 30)
        _ = playback.advance(to: 0, levels: backlog, appendedCount: 30, epoch: 0, isHeld: false, reduceMotion: false)
        #expect(playback.queue.count <= MeterPlayback.maximumBacklog)
    }

    @Test func heldBarsShowTheEndingOfTheRecording() {
        var playback = MeterPlayback(barCount: 15)
        _ = playback.advance(to: 0, levels: [], appendedCount: 0, epoch: 0, isHeld: false, reduceMotion: false)
        // A burst still queued when the recording ends.
        _ = playback.advance(to: 0.001, levels: Self.burst, appendedCount: 5, epoch: 0, isHeld: false, reduceMotion: false)
        #expect(!playback.queue.isEmpty)
        let held = playback.advance(
            to: 0.002, levels: Self.burst, appendedCount: 5, epoch: 0, isHeld: true, reduceMotion: false
        )
        #expect(playback.queue.isEmpty)
        #expect(playback.released.last == CGFloat(Float(1.0)))
        // Settled on that shape, not easing towards it under a paused clock.
        #expect(held[14] > 0.4)
    }

    @Test func aHeldRowKeepsEveryLevelOfALongBacklog() {
        var playback = MeterPlayback(barCount: 15)
        _ = playback.advance(to: 0, levels: [], appendedCount: 0, epoch: 0, isHeld: false, reduceMotion: false)
        let ramp = (1...12).map { Float($0) / 12 }
        _ = playback.advance(to: 0.001, levels: ramp, appendedCount: 12, epoch: 0, isHeld: true, reduceMotion: false)
        #expect(Array(playback.released.suffix(12)) == ramp.map { CGFloat($0) })
    }

    @Test func aKeyboardOpeningMidSessionStartsFromTheLatestLevels() {
        var playback = MeterPlayback(barCount: 3)
        let shown = playback.advance(
            to: 0, levels: [0.1, 0.2, 0.3, 0.4], appendedCount: 40, epoch: 2, isHeld: false, reduceMotion: false
        )
        #expect(playback.queue.isEmpty)
        #expect(playback.released == [0.2, 0.3, 0.4].map { CGFloat(Float($0)) })
        #expect(shown.allSatisfy { $0 > 0 })
    }

    @Test func reduceMotionPlacesEveryLevelAtOnce() {
        var playback = MeterPlayback(barCount: 15)
        _ = playback.advance(to: 0, levels: [], appendedCount: 0, epoch: 0, isHeld: false, reduceMotion: true)
        let shown = playback.advance(
            to: 0.01, levels: Self.burst, appendedCount: 5, epoch: 0, isHeld: false, reduceMotion: true
        )
        #expect(playback.queue.isEmpty)
        #expect(shown[14] > 0.4)
    }
}

/// The view that draws the bars. What matters is that it cannot freeze: the
/// waveform that "did not load" was a row whose clock never started, drawing
/// the first burst and nothing after it.
@MainActor
struct LiveWaveformViewTests {
    private static let burst: [Float] = [0.2, 0.4, 0.6, 0.8, 1.0]

    private static func input(levels: [Float], appended: Int, isHeld: Bool = false) -> LiveWaveformView.Input {
        LiveWaveformView.Input(
            levels: levels, appendedCount: appended, epoch: 0, isHeld: isHeld, reduceMotion: false
        )
    }

    @Test func levelsMoveTheBarsWithNoClockRunning() {
        // Not in a window, so no display link: the case a stopped clock leaves.
        let view = LiveWaveformView(barCount: 15)
        view.update(Self.input(levels: [], appended: 0), now: 0)
        #expect(view.shown.allSatisfy { $0 == 0 })

        view.update(Self.input(levels: Self.burst, appended: 5), now: 0.25)
        #expect(view.shown[14] > 0.4)

        let next = Self.burst + [0.1, 0.1, 0.1, 0.1, 0.1]
        view.update(Self.input(levels: next, appended: 10), now: 0.5)
        #expect(view.shown[14] < 0.2)
    }

    @Test func heldBarsKeepTheShapeTheyEndedOn() {
        let view = LiveWaveformView(barCount: 15)
        view.update(Self.input(levels: Self.burst, appended: 5, isHeld: true), now: 0)
        let ending = view.shown
        view.update(Self.input(levels: Self.burst, appended: 5, isHeld: true), now: 1)
        #expect(view.shown == ending)
        #expect(ending[14] > 0.4)
    }

    @Test func arrivingLevelsWaitOnlyForAClockThatIsTicking() {
        // Running, and drew a moment ago: the next frame plays the burst.
        #expect(!LiveWaveformView.landsOnArrival(clockIsRunning: true, lastFrameAt: 10, now: 10.02))
        // Running, but no frame for longer than a burst takes to arrive.
        #expect(LiveWaveformView.landsOnArrival(clockIsRunning: true, lastFrameAt: 10, now: 10.5))
        // Not running at all.
        #expect(LiveWaveformView.landsOnArrival(clockIsRunning: false, lastFrameAt: 10, now: 10))
    }
}
