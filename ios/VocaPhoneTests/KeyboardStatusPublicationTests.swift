import Foundation
import Testing

struct KeyboardStatusPublicationTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func decide(
        lastAt: Date?,
        reached: Bool?,
        forced: Bool = false,
        after seconds: TimeInterval
    ) -> Bool {
        KeyboardStatusPublication.shouldPublish(
            lastPublishedAt: lastAt,
            lastReachedContainer: reached,
            forced: forced,
            now: now.addingTimeInterval(seconds),
            minimumInterval: 10,
            minimumGap: 1
        )
    }

    @Test func aFreshInstanceAlwaysTests() {
        #expect(decide(lastAt: nil, reached: nil, after: 0))
    }

    @Test func aFreshProofSkipsAMereReappearance() {
        #expect(!decide(lastAt: now, reached: true, after: 3))
        #expect(decide(lastAt: now, reached: true, after: 10))
    }

    /// "Still off" is exactly what a setup page may be waiting on, and a failed
    /// write costs nothing, so it is never throttled beyond the floor.
    @Test func aFailedProofIsTestedAgainOnEveryAppearance() {
        #expect(decide(lastAt: now, reached: false, after: 1.5))
    }

    @Test func anAskBypassesTheIntervalButNotTheFloor() {
        #expect(decide(lastAt: now, reached: true, forced: true, after: 1.5))
        #expect(!decide(lastAt: now, reached: true, forced: true, after: 0.2))
    }

    /// The setup pages ask several times a second. Every ask used to be a file
    /// write on the extension's main thread while the keyboard slid in.
    @Test func theFloorHoldsAgainstAPingLoop() {
        for ask in stride(from: 0.2, to: 1.0, by: 0.2) {
            #expect(!decide(lastAt: now, reached: false, forced: true, after: ask))
        }
    }
}
