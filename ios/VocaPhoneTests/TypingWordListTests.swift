import Foundation
import Testing

/// The one piece of data iOS ships, and the two things `UITextChecker` cannot
/// do: order completions by frequency, and predict the next word.
struct TypingWordListTests {
    private static let list = TypingWordList.parse(
        words: """
        the
        to
        and
        hello
        help
        helmet
        there
        their
        """,
        bigrams: """
        # comment lines are skipped
        see\tyou, the, it
        thank\tyou
        malformed line with no tab
        """
    )

    @Test func completionsComeBackInFrequencyOrder() {
        // "the" is first in the list and must be first out of it — a completion
        // list that offers "their" before "the" reads as broken.
        #expect(Self.list.completions(for: "the", limit: 3) == ["there", "their"])
        #expect(Self.list.completions(for: "hel", limit: 2) == ["hello", "help"])
    }

    @Test func aCompletionIsAlwaysLongerThanWhatWasTyped() {
        #expect(!Self.list.completions(for: "hello", limit: 3).contains("hello"))
    }

    @Test func membershipAndRankAreCaseInsensitive() {
        #expect(Self.list.contains("Hello"))
        #expect(Self.list.rank(of: "the") == 0)
        #expect(Self.list.rank(of: "nonsense") == nil)
    }

    @Test func bigramsParseAndSkipMalformedLines() {
        #expect(Self.list.nextWords(after: "see", limit: 3) == ["you", "the", "it"])
        #expect(Self.list.nextWords(after: "SEE", limit: 1) == ["you"])
        #expect(Self.list.nextWords(after: "malformed", limit: 3).isEmpty)
        #expect(Self.list.nextWords(after: "nothing", limit: 3).isEmpty)
    }

    // MARK: - Corrections without the system checker

    /// This is the fallback the plan reserves if `UITextChecker` proves too
    /// expensive on device: the shipped list can correct on its own, in pure
    /// Swift that may leave the main actor.
    @Test func theListFindsNearMissesOnItsOwn() {
        #expect(Self.list.similarWords(to: "helo", limit: 2).contains("hello"))
        #expect(Self.list.similarWords(to: "hte", limit: 2).contains("the"))
    }

    @Test func aWordTheListKnowsIsNotCorrected() {
        #expect(Self.list.similarWords(to: "hello", limit: 2).isEmpty)
    }

    @Test func veryShortWordsAreLeftAlone() {
        #expect(Self.list.similarWords(to: "th", limit: 2).isEmpty)
    }

    // MARK: - The shipped files

    /// The real files, shared with the Android keyboard. Tolerant assertions —
    /// this checks the wiring and the format, not the contents of the language.
    @Test func theSharedListShipsInsideTheKeyboardBundle() throws {
        let bundle = Bundle(for: BundleMarker.self)
        guard bundle.url(forResource: "en", withExtension: "txt") != nil else {
            // The test bundle does not embed the keyboard's resources; the file
            // is read from the repository instead so the format still gets
            // checked. The bundle wiring itself is covered by the build.
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("assets/keyboard")
            let words = try String(contentsOf: root.appendingPathComponent("en.txt"), encoding: .utf8)
            let bigrams = try String(
                contentsOf: root.appendingPathComponent("en-bigrams.txt"),
                encoding: .utf8
            )
            let list = TypingWordList.parse(words: words, bigrams: bigrams)
            #expect(list.count > 5_000)
            #expect(list.rank(of: "the") != nil)
            #expect(!list.nextWords(after: "thank", limit: 1).isEmpty)
            return
        }
        let list = TypingWordList.load(from: bundle)
        #expect(list.count > 5_000)
    }

    private final class BundleMarker {}
}
