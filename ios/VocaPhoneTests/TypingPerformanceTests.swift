import XCTest

/// XCTest performance measurements for the pure typing path.
///
/// These tests intentionally construct their inputs outside the measured block:
/// the result is about ranking/correction work, not test-fixture allocation.
/// Xcode records the clock, CPU, and memory metrics so a maintainer can establish
/// a simulator/device baseline in the test plan without making hosted-runner
/// wall-clock noise a hard release gate.
final class TypingPerformanceTests: XCTestCase {
    private let stripContext = TypingCandidates.Context(
        composition: "teh",
        systemCompletions: ["the", "tech", "then", "their"],
        systemGuesses: ["the", "tee", "ten"],
        listCompletions: ["the", "them", "there", "these"],
        isKnownToChecker: false,
        isInWordList: false,
    )

    private let wordList: TypingWordList = {
        let words = (0..<10_000).map { index in
            index.isMultiple(of: 10) ? "keyboard\(index)" : "word\(index)"
        }
        return TypingWordList(words: words, bigrams: [:])
    }()

    func testTypingStripPerformance() {
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            _ = TypingCandidates.strip(stripContext)
        }
    }

    func testWordListCompletionPerformance() {
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            _ = wordList.completions(for: "keyboard", limit: 3)
        }
    }
}
